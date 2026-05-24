//
//  CameraManager.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

@preconcurrency import AVFoundation
import Combine
import CoreImage
import UIKit

/// Owns the capture session and feeds the SwiftUI preview, per-frame pixels,
/// and captured photos.
///
/// The two hook methods — `didReceiveFrame(_:)` and `didCapturePhoto(_:)` — are
/// intentionally empty. Fill them in to do something with the pixels.
///
/// AVFoundation drives this class from its own background queues rather than the
/// main actor, so it is `nonisolated`. Access to the session is confined to
/// `sessionQueue` (hence `@unchecked Sendable`), and the UI-facing `@Published`
/// values are explicitly `@MainActor` so SwiftUI only ever reads them on main.
nonisolated final class CameraManager:
    NSObject,
    ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCapturePhotoCaptureDelegate,
    @unchecked Sendable {

    /// The session the SwiftUI preview layer renders.
    let session = AVCaptureSession()

    /// Cameras this device actually has (e.g. wide, ultra-wide, front).
    @MainActor @Published private(set) var availableCameras: [AVCaptureDevice] = []

    /// The camera currently feeding the session.
    @MainActor @Published private(set) var selectedCamera: AVCaptureDevice?

    /// What the UI should show: live camera, an in-flight OCR job, the
    /// finished overlay, or an error from the last attempt.
    @MainActor @Published private(set) var captureState: CaptureState = .idle

    /// Tracked bounding boxes for the most recent live frame, in Vision-normalized
    /// coordinates (origin bottom-left, components in [0, 1]). The UI overlays
    /// these on top of the preview.
    @MainActor @Published private(set) var liveDetections: [TrackedBox] = []

    enum CaptureState: @unchecked Sendable {
        case idle
        case processing
        case result(UIImage)
        case failed(String)
    }

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    /// Serial queue for all session configuration and start/stop work, so the
    /// main thread never blocks on `startRunning()`.
    private let sessionQueue = DispatchQueue(label: "camera.session")

    /// Dedicated queue on which live frames are delivered.
    private let videoQueue = DispatchQueue(label: "camera.video")

    /// Off-main snapshot of the latest displayed detections, mirroring
    /// `liveDetections` so the photo callback can pick a crop quad without
    /// hopping to the main actor. Protected by `detectionsLock`.
    private let detectionsLock = NSLock()
    private var latestDetections: [TrackedBox] = []


    /// Talks to the PaddleOCR job API. The API key is read from the app
    /// bundle's Info.plist (populated from `secrets.xcconfig` at build time) —
    /// see `Secrets.swift`.
    private let paddleClient = PaddleOCRClient.makeDefault()

    /// Reused to turn camera pixel buffers into JPEG data.
    private let ciContext = CIContext()

    /// YOLOE-26L segmentation detector — replaces both the legacy doc-seg and
    /// the YOLOv8-world detectors. Each detection carries an oriented quad
    /// derived from the instance mask. Nil if the model fails to load.
    private let segDetector = YoloESegDetector.makeDefault()
    /// ByteTrack-style association across frames so the boxes flow smoothly.
    private let tracker = ByteTracker()
    /// Hide a tracked box if this fraction of its area lies inside a larger
    /// sibling — keeps the screen-inside-laptop / label-on-package case clean.
    /// Display-only; the tracker keeps the hidden box around for re-association.
    var displayContainmentThreshold: CGFloat = 0.6

    // MARK: - Empty hooks for you to fill in

    /// Called on every live frame.
    /// Runs on `videoQueue` (a background thread) — dispatch to main before
    /// touching any UI.
    private func didReceiveFrame(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let detections = segDetector?.detect(in: image) ?? []
        let tracked = tracker.update(detections: detections)
        let displayed = TrackedBox.removingContained(
            tracked,
            containmentThreshold: displayContainmentThreshold
        )
        detectionsLock.lock()
        latestDetections = displayed
        detectionsLock.unlock()
        Task { @MainActor in self.liveDetections = displayed }
    }

    /// Called once each time the shutter button finishes taking a photo.
    /// Runs on a background thread — dispatch to main before touching any UI.
    ///
    /// If a tracked detection is currently "highlighted" (the red trapezoid in
    /// the preview), the captured frame is cropped and perspective-corrected
    /// to that quad before being sent to OCR — otherwise the full frame is used.
    private func didCapturePhoto(_ pixelBuffer: CVPixelBuffer) {
        detectionsLock.lock()
        let snapshot = latestDetections
        detectionsLock.unlock()

        let winner = TrackedBox.highlightWinner(in: snapshot)
        let paddedQuad: Quad? = winner.map { box in
            let raw = box.normalizedQuad ?? Quad(rect: box.normalizedRect)
            let padding = YoloEClasses.cropPadding(for: box.classId)
            return raw.expanded(byFactor: padding)
        }

        let imageData: Data? = {
            if let quad = paddedQuad {
                return jpegData(from: pixelBuffer, perspectiveCorrectingTo: quad)
            }
            return jpegData(from: pixelBuffer)
        }()

        guard let imageData else {
            Task { @MainActor in
                self.captureState = .failed("Failed to encode the captured photo.")
            }
            return
        }
        Task { @MainActor in self.captureState = .processing }
        Task { await runOCR(on: imageData) }
    }

    /// Reset back to live camera. Call from the UI when the user dismisses
    /// the result or error overlay.
    @MainActor
    func resetCaptureState() {
        captureState = .idle
        start()
    }

    // MARK: - Lifecycle

    /// Requests camera access, configures the session once, and starts it.
    func start() {
        requestAccess { [weak self] granted in
            guard let self, granted else { return }
            self.sessionQueue.async {
                self.configureSessionIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Camera selection

    /// Switches the live feed to one of the `availableCameras`.
    func selectCamera(_ camera: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            // Drop the current camera input.
            for input in self.session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    self.session.removeInput(deviceInput)
                }
            }

            // Attach the chosen camera.
            guard let newInput = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(newInput) else { return }
            self.session.addInput(newInput)

            Task { @MainActor in self.selectedCamera = camera }
        }
    }

    // MARK: - Photo capture

    /// Takes a still photo; the result is delivered to `didCapturePhoto(_:)`.
    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Request BGRA pixels so the result is guaranteed to carry a CVPixelBuffer.
            let settings = AVCapturePhotoSettings(format: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Session configuration

    private func configureSessionIfNeeded() {
        // Inputs are only added during configuration, so an empty list means
        // we haven't set the session up yet.
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        let cameras = discoverCameras()
        Task { @MainActor in self.availableCameras = cameras }

        // Start on the back camera, falling back to whatever is first.
        let defaultCamera = cameras.first { $0.position == .back } ?? cameras.first
        if let defaultCamera,
           let input = try? AVCaptureDeviceInput(device: defaultCamera),
           session.canAddInput(input) {
            session.addInput(input)
            Task { @MainActor in self.selectedCamera = defaultCamera }
        }

        // Per-frame output. BGRA keeps frames consistent with captured photos.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Still-photo output.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
    }

    /// Finds every built-in camera on the device, front and back.
    private func discoverCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    private func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default:
            completion(false)
        }
    }

    // MARK: - PaddleOCR upload

    /// Uploads the captured photo to PaddleOCR, builds a `VirtualDocument`
    /// from the first returned page, renders the color-coded overlay, and
    /// publishes it via `captureState` for the UI.
    private func runOCR(on imageData: Data) async {
        guard PaddleOCRClient.isAPIKeyConfigured else {
            await publishFailure("Set the PaddleOCR API key in secrets.xcconfig before capturing.")
            return
        }

        let tempDirectory = FileManager.default.temporaryDirectory
        let imageURL = tempDirectory.appendingPathComponent("capture-\(UUID().uuidString).jpg")
        let outputDirectory = tempDirectory.appendingPathComponent("paddleocr-\(UUID().uuidString)")

        do {
            try imageData.write(to: imageURL)
            let pages = try await paddleClient.process(
                fileURL: imageURL,
                optionalPayload: OptionalPayload(useDocOrientationClassify: true),
                outputDirectory: outputDirectory
            )

            guard let page = pages.first else {
                await publishFailure("PaddleOCR returned no pages.")
                return
            }
            guard let pruned = page.prunedResult else {
                await publishFailure("PaddleOCR response was missing layout data.")
                return
            }

            // Prefer the deskewed/oriented preprocessed image (its coordinate
            // space matches the bboxes). Fall back to the original capture.
            let sourceImage: UIImage = {
                if let url = page.preprocessedImageURL,
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    return img
                }
                return UIImage(data: imageData) ?? UIImage()
            }()

            let document = VirtualDocument.make(from: pruned, image: sourceImage)
            let overlay = document.render()
            let croppedImage = UIImage(data: imageData) ?? overlay
            await MainActor.run {
                self.captureState = .result(croppedImage)
                self.stop()
            }
        } catch {
            await publishFailure("PaddleOCR error: \(error)")
        }
    }

    @MainActor
    private func publishFailure(_ message: String) {
        captureState = .failed(message)
    }

    /// Encodes a camera pixel buffer as JPEG data for upload.
    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }

    /// Crops + perspective-corrects the pixel buffer to the given Vision-normalized
    /// quad, then JPEG-encodes the rectified result.
    ///
    /// Uses `CIPerspectiveCorrection`, which auto-sizes the output rectangle to
    /// the average length of opposing input sides — so the document's natural
    /// aspect ratio is preserved and features (text, lines, edges) aren't
    /// stretched. The 4 corners are re-sorted into TL/TR/BR/BL in CIImage space
    /// (bottom-left origin) so the filter receives a correctly-oriented quad
    /// regardless of which corner the detector listed first.
    private func jpegData(from pixelBuffer: CVPixelBuffer,
                          perspectiveCorrectingTo quad: Quad) -> Data? {
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = baseImage.extent
        // Clamp to the input extent so a class with generous padding that
        // pushes a corner slightly past the image edge samples edge pixels
        // instead of black borders.
        let ciImage = baseImage.clampedToExtent()

        // Vision-normalized (bottom-left, [0,1]) -> CIImage pixel coords (same
        // origin convention, so no Y flip).
        let pixelPoints = quad.points.map { p in
            CGPoint(x: extent.minX + p.x * extent.width,
                    y: extent.minY + p.y * extent.height)
        }

        // Standard "order_points" sort in bottom-left-origin space:
        //   BL = min(x + y)     TR = max(x + y)
        //   TL = min(x - y)     BR = max(x - y)
        let sums = pixelPoints.map { $0.x + $0.y }
        let diffs = pixelPoints.map { $0.x - $0.y }
        guard let bl = sums.indices.min(by: { sums[$0] < sums[$1] }),
              let tr = sums.indices.max(by: { sums[$0] < sums[$1] }),
              let tl = diffs.indices.min(by: { diffs[$0] < diffs[$1] }),
              let br = diffs.indices.max(by: { diffs[$0] < diffs[$1] }),
              Set([bl, tr, tl, br]).count == 4 else {
            // Degenerate quad — fall back to a plain encode of the full frame.
            return jpegData(from: pixelBuffer)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return jpegData(from: pixelBuffer)
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: pixelPoints[tl]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: pixelPoints[tr]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: pixelPoints[bl]), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: pixelPoints[br]), forKey: "inputBottomRight")

        guard let output = filter.outputImage,
              let cgImage = ciContext.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }

    // MARK: - AVCapture delegate callbacks

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        didReceiveFrame(pixelBuffer)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        AudioServicesDisposeSystemSoundID(1108)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        AudioServicesDisposeSystemSoundID(1108)
        guard error == nil, let pixelBuffer = photo.pixelBuffer else { return }
        didCapturePhoto(pixelBuffer)
    }
}
