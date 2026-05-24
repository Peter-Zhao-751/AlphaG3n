//
//  CameraManager.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

@preconcurrency import AVFoundation
import Combine
import UIKit

/// Owns the capture session and drives the SwiftUI preview + photo capture
/// pipeline.
///
/// AVFoundation calls back on its own queues, so this class is `nonisolated`
/// with mutable state confined to `sessionQueue` (hence `@unchecked
/// Sendable`). UI-facing `@Published` values are explicitly `@MainActor` so
/// SwiftUI only ever reads them on main.
///
/// First-init and shutter-to-processing latency are deliberately tuned:
///   * Session configuration starts as soon as this object is constructed if
///     camera access is already granted, overlapping with SwiftUI's first
///     render pass.
///   * The UI flips to `.processing` synchronously the moment the shutter is
///     tapped — encoding and upload happen on a detached task afterwards.
///   * Per-frame `CMSampleBuffer`s are routed through the YOLOE detector +
///     ByteTracker so the UI can highlight a quad to perspective-correct
///     the captured photo against before upload.
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
    /// main thread never blocks on `startRunning()`. `.userInitiated` keeps
    /// it ahead of background work on busy devices.
    private let sessionQueue = DispatchQueue(
        label: "camera.session",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

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

    /// Cached at construction so the hot photo path never bounces through
    /// `Bundle.main.object(forInfoDictionaryKey:)` on every shot.
    private let apiKeyConfigured = PaddleOCRClient.isAPIKeyConfigured

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

    override init() {
        super.init()
        // Pre-warm the session while SwiftUI is still building the first
        // frame. Repeat launches almost always land in `.authorized`, so
        // overlapping configuration with view construction shaves the
        // visible "camera takes a beat to appear" pause off cold launches.
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            sessionQueue.async { [self] in
                configureSessionIfNeeded()
            }
        }
        // Warm the TLS session to the OCR endpoint. First photo would
        // otherwise pay the full handshake on the upload path; doing this
        // here lets it overlap with the user composing their first shot.
        if apiKeyConfigured {
            let client = paddleClient
            Task.detached(priority: .utility) {
                await client.warmUp()
            }
        }
    }

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
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runOCR(on: imageData)
        }
    }

    /// Reset back to live camera. Call from the UI when the user dismisses
    /// the result or error overlay.
    @MainActor
    func resetCaptureState() {
        captureState = .idle
        start()
    }

    // MARK: - Lifecycle

    /// Requests camera access (if needed), configures the session once, and
    /// starts it. Safe to call repeatedly: configuration is idempotent and
    /// `startRunning()` is a no-op when already running.
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

            for input in self.session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    self.session.removeInput(deviceInput)
                }
            }

            guard let newInput = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(newInput) else { return }
            self.session.addInput(newInput)

            Task { @MainActor in self.selectedCamera = camera }
        }
    }

    // MARK: - Photo capture

    /// Takes a still photo; the result is delivered to `photoOutput(_:didFinishProcessingPhoto:error:)`.
    ///
    /// State flips to `.processing` synchronously — the user gets feedback in
    /// the same frame as the tap. Capture queueing happens on the session
    /// queue right after, with no further main-thread work on this path.
    func capturePhoto() {
        Task { @MainActor in self.captureState = .processing }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = self.makePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Requests BGRA pixels so the result is guaranteed to carry a
    /// `CVPixelBuffer` — the perspective-correction crop in
    /// `didCapturePhoto` reads `photo.pixelBuffer`, which is nil when the
    /// photo is delivered as a pre-encoded JPEG.
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        settings.photoQualityPrioritization = .balanced
        return settings
    }

    // MARK: - Session configuration

    private func configureSessionIfNeeded() {
        // Inputs are only added during configuration, so an empty list means
        // we haven't set the session up yet.
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        let cameras = discoverCameras()
        let defaultCamera = cameras.first { $0.position == .back } ?? cameras.first

        if let defaultCamera,
           let input = try? AVCaptureDeviceInput(device: defaultCamera),
           session.canAddInput(input) {
            session.addInput(input)
        }

        // Per-frame output for live detection. BGRA keeps frames consistent
        // with captured photos.
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
            configurePhotoOutput(for: defaultCamera)
        }

        session.commitConfiguration()

        // Batch the two `@Published` mutations into a single MainActor hop —
        // SwiftUI sees one update instead of two back-to-back rebuilds.
        Task { @MainActor in
            self.availableCameras = cameras
            self.selectedCamera = defaultCamera
        }
    }

    /// Caps the ISP at ~12 MP. Modern iPhones default to 48 MP photos which
    /// take noticeably longer to encode (~150-300 ms) and produce ~10× the
    /// upload bytes for no OCR-relevant gain. Falls back to whatever the
    /// device exposes if 12 MP isn't a listed dimension on this sensor.
    private func configurePhotoOutput(for device: AVCaptureDevice?) {
        photoOutput.maxPhotoQualityPrioritization = .balanced

        guard let device else { return }
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        guard !supported.isEmpty else { return }

        let preferred = CMVideoDimensions(width: 4032, height: 3024)
        if let exact = supported.first(where: { $0.width == preferred.width && $0.height == preferred.height }) {
            photoOutput.maxPhotoDimensions = exact
            return
        }
        photoOutput.maxPhotoDimensions = Self.bestDimension(
            from: supported,
            preferred: preferred
        )
    }

    /// Pick the largest supported dimension that's still ≤ `preferred`'s
    /// pixel count, falling back to the smallest available if everything
    /// exceeds the cap. Pulled out so the type-checker doesn't choke on the
    /// closure soup it would otherwise have to inline.
    private static func bestDimension(
        from supported: [CMVideoDimensions],
        preferred: CMVideoDimensions
    ) -> CMVideoDimensions {
        let cap = Int64(preferred.width) * Int64(preferred.height)
        var bestUnder: CMVideoDimensions?
        var bestUnderPixels: Int64 = 0
        var smallestOver: CMVideoDimensions?
        var smallestOverPixels: Int64 = .max

        for dim in supported {
            let pixels = Int64(dim.width) * Int64(dim.height)
            if pixels <= cap {
                if pixels > bestUnderPixels {
                    bestUnderPixels = pixels
                    bestUnder = dim
                }
            } else if pixels < smallestOverPixels {
                smallestOverPixels = pixels
                smallestOver = dim
            }
        }
        return bestUnder ?? smallestOver ?? preferred
    }

    /// Finds every built-in camera on the device, front and back.
    private func discoverCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .unspecified
        ).devices
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

    // MARK: - OCR

    /// JPEG quality for re-encoded uploads. 0.85 is the sweet spot for OCR
    /// — character edges stay crisp, but file size drops ~20% versus 0.9.
    /// The Baidu pipeline downsamples to `maxPixels` regardless, so paying
    /// extra bytes for higher quality buys nothing.
    private static let uploadJPEGQuality: CGFloat = 0.85

    /// The OCR pipeline. Sequenced to keep wall time minimal:
    ///   1. Pre-shrink the photo to fit `maxPixels` and bake any EXIF
    ///      rotation into the pixels. This cuts upload bytes 70-80% on a
    ///      12 MP iPhone capture and removes server-side downsample work.
    ///   2. Submit to PaddleOCR. With orient + unwarp on, Baidu may rotate
    ///      / dewarp internally; the response's `preprocessedImageURL`
    ///      points at the canonical post-transform image.
    ///   3. Once Baidu responds, run CRAFT on that *same* preprocessed
    ///      image so the augmentation overlap math is coordinate-correct.
    ///      CRAFT can't run in parallel with Baidu when preprocessing is
    ///      on — the coordinate frames would diverge — so we accept the
    ///      ~100-500 ms serial cost in exchange for correctness.
    ///   4. Render the merged layout on the preprocessed image (its size
    ///      matches `pruned.width × pruned.height`, so no rescale at draw).
    private func runOCR(on rawJPEG: Data) async {
        guard apiKeyConfigured else {
            await publishFailure("Set the PaddleOCR API key in secrets.xcconfig before capturing.")
            return
        }

        let optional = OptionalPayload()
        guard let prepared = Self.prepareForUpload(
            rawJPEG,
            maxPixels: optional.maxPixels,
            quality: Self.uploadJPEGQuality
        ) else {
            await publishFailure("Failed to decode the captured photo.")
            return
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddleocr-\(UUID().uuidString)", isDirectory: true)
        let filename = "capture-\(UUID().uuidString).jpg"

        do {
            let pages = try await paddleClient.process(
                imageData: prepared.jpeg,
                filename: filename,
                mimeType: "image/jpeg",
                optionalPayload: optional,
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

            // CRAFT consumes the same image Baidu's bboxes describe so the
            // overlap filter compares apples to apples. The preprocessed
            // URL is the post-orientation, post-dewarp image; if it's
            // absent (server skipped preprocessing for this page) we fall
            // back to the upright bytes we sent.
            let craftSource = Self.loadCraftSource(
                preprocessedURL: page.preprocessedImageURL,
                fallback: prepared.image
            )
            let craftBoxes = await Self.detectCraftBoxes(in: craftSource)
            let augmented = Self.augment(pruned: pruned, with: craftBoxes)
            let renderSource = craftSource

            // Document build + render is pure CPU work; offload so this
            // method returns to its caller as fast as possible. On dense
            // pages this is 50-200 ms of layout sort + path drawing that
            // would otherwise stall the publish step.
            let overlay = await Task.detached(priority: .userInitiated) { () -> UIImage in
                let document = VirtualDocument.make(from: augmented, image: renderSource)
                return document.render()
            }.value

            await MainActor.run {
                self.captureState = .result(overlay)
                self.stop()
            }
        } catch {
            await publishFailure("PaddleOCR error: \(error)")
        }
    }

    /// Decodes the captured JPEG, downsamples to fit `maxPixels` (matching
    /// Baidu's `maxPixels` so the server doesn't redo the work), bakes any
    /// EXIF rotation into the pixels, and re-encodes. Returns both the
    /// upload bytes and the decoded `UIImage` so the caller avoids a
    /// second decode for the fallback path.
    ///
    /// Hot path: image already upright AND already within the pixel cap —
    /// returns the original bytes verbatim and only decodes once.
    private static func prepareForUpload(
        _ data: Data,
        maxPixels: Int,
        quality: CGFloat
    ) -> (jpeg: Data, image: UIImage)? {
        guard let decoded = UIImage(data: data) else { return nil }

        let pixelCount = Int(decoded.size.width * decoded.size.height)
        let needsRotate = decoded.imageOrientation != .up
        let needsDownsample = maxPixels > 0 && pixelCount > maxPixels

        if !needsRotate && !needsDownsample {
            return (data, decoded)
        }

        let targetSize: CGSize
        if needsDownsample {
            // Linear ratio preserves aspect; pixel count after = maxPixels.
            // Floor at 1 px in each dim — a 0-size renderer crashes.
            let ratio = (Double(maxPixels) / Double(pixelCount)).squareRoot()
            targetSize = CGSize(
                width: max(1, decoded.size.width * CGFloat(ratio)),
                height: max(1, decoded.size.height * CGFloat(ratio))
            )
        } else {
            targetSize = decoded.size
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 1:1 pixel mapping; size is reported in points.
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let prepared = renderer.image { _ in
            decoded.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let encoded = prepared.jpegData(compressionQuality: quality) else {
            return nil
        }
        return (encoded, prepared)
    }

    /// Loads the deskewed image PaddleOCR returned, falling back to the
    /// upright bytes we sent if the URL is missing or unreadable. The
    /// preprocessed image is the coordinate authority for Baidu's bboxes —
    /// CRAFT and the renderer must consume it (not the original upright)
    /// to stay aligned.
    private static func loadCraftSource(
        preprocessedURL: URL?,
        fallback: UIImage
    ) -> UIImage {
        if let url = preprocessedURL,
           let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let img = UIImage(data: data) {
            return img
        }
        return fallback
    }

    /// Runs the on-device CRAFT detector. Failures (model not bundled,
    /// inference error) leave the Baidu flow untouched, but they're logged
    /// so a missing model doesn't disappear silently the way it used to.
    ///
    /// Thresholds use CRAFT's defaults (0.7 / 0.4 / 10). The previous code
    /// raised them substantially to suppress false positives that were
    /// largely artifacts of the broken preprocessing (non-aspect-preserving
    /// stretch + raw-context Y flip), both of which are now fixed.
    ///
    /// Inference runs on its own detached task so it doesn't share the
    /// PaddleOCR awaiter's priority slot. Apple's Core ML scheduler then
    /// places it on Neural Engine / GPU as it sees fit.
    private static func detectCraftBoxes(in image: UIImage) async -> [CGRect] {
        await Task.detached(priority: .userInitiated) { () -> [CGRect] in
            let craft = CraftModel()
            do {
                return try craft.detect(in: image).map(\.rect)
            } catch {
                print("CRAFT augmentation skipped: \(error)")
                return []
            }
        }.value
    }

    /// Splices CRAFT survivors into the Baidu `PrunedResult`. Skips when
    /// CRAFT produced nothing useful; otherwise returns a new value with the
    /// extra blocks appended.
    private static func augment(
        pruned: VirtualDocument.PrunedResult,
        with craftBoxes: [CGRect]
    ) -> VirtualDocument.PrunedResult {
        guard !craftBoxes.isEmpty else { return pruned }
        let extras = LayoutAugmentation.extraBlocks(
            craftBoxes: craftBoxes,
            existing: pruned.parsingResList,
            pageSize: CGSize(width: pruned.width, height: pruned.height)
        )
        guard !extras.isEmpty else { return pruned }
        return VirtualDocument.PrunedResult(
            width: pruned.width,
            height: pruned.height,
            parsingResList: pruned.parsingResList + extras
        )
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
        if let error {
            Task { @MainActor in
                self.captureState = .failed("Capture failed: \(error.localizedDescription)")
            }
            return
        }
        AudioServicesDisposeSystemSoundID(1108)
        guard let pixelBuffer = photo.pixelBuffer else {
            Task { @MainActor in
                self.captureState = .failed("Failed to access the captured pixel buffer.")
            }
            return
        }
        didCapturePhoto(pixelBuffer)
    }
}
