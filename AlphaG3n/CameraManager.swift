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

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    /// Serial queue for all session configuration and start/stop work, so the
    /// main thread never blocks on `startRunning()`.
    private let sessionQueue = DispatchQueue(label: "camera.session")

    /// Dedicated queue on which live frames are delivered.
    private let videoQueue = DispatchQueue(label: "camera.video")


    /// Talks to the PaddleOCR job API. The API key is read from the app
    /// bundle's Info.plist (populated from `secrets.xcconfig` at build time) —
    /// see `Secrets.swift`.
    private let paddleClient = PaddleOCRClient.makeDefault()

    /// Reused to turn camera pixel buffers into JPEG data.
    private let ciContext = CIContext()

    // MARK: - Empty hooks for you to fill in

    /// Called on every live frame.
    /// Runs on `videoQueue` (a background thread) — dispatch to main before
    /// touching any UI.
    private func didReceiveFrame(_ pixelBuffer: CVPixelBuffer) {
        
    }

    /// Called once each time the shutter button finishes taking a photo.
    /// Runs on a background thread — dispatch to main before touching any UI.
    private func didCapturePhoto(_ pixelBuffer: CVPixelBuffer) {
        guard let imageData = jpegData(from: pixelBuffer) else {
            print("PaddleOCR: failed to encode the captured photo")
            return
        }
        Task { await runOCR(on: imageData) }
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

    /// Uploads the captured photo to PaddleOCR and prints the extracted output.
    private func runOCR(on imageData: Data) async {
        guard PaddleOCRClient.isAPIKeyConfigured else {
            print("PaddleOCR: set the API key in PaddleOCRClient+APIKey.swift before capturing a photo.")
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
                outputDirectory: outputDirectory,
                progress: { event in print("PaddleOCR progress: \(event)") }
            )

            print("PaddleOCR: extracted \(pages.count) page(s)")
            for page in pages {
                print("----- Page \(page.pageIndex) -----")
                if page.blocks.isEmpty {
                    // We didn't recognize any bbox blocks in the response;
                    // dump the raw JSON so the schema can be inspected and the
                    // decoder in PaddleOCRModel.swift refined.
                    print("No decoded blocks. Raw JSON:")
                    print(page.rawJSON)
                } else {
                    for block in page.blocks {
                        let bbox = block.bbox
                            .map { String(format: "%.1f", $0) }
                            .joined(separator: ", ")
                        print("[\(block.label)] bbox=[\(bbox)]")
                        if !block.content.isEmpty {
                            print(block.content)
                        }
                    }
                }
                if !page.inlineImages.isEmpty {
                    print("Inline images: \(page.inlineImages)")
                }
                if !page.outputImages.isEmpty {
                    print("Output images: \(page.outputImages)")
                }
            }
        } catch {
            print("PaddleOCR error: \(error)")
        }
    }

    /// Encodes a camera pixel buffer as JPEG data for upload.
    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
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

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let pixelBuffer = photo.pixelBuffer else { return }
        didCapturePhoto(pixelBuffer)
    }
}
