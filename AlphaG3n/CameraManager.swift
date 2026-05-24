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

    /// The in-flight read job, retained so the UI's Cancel button can abort it.
    /// Assigned on the main actor when a capture begins processing; cleared on
    /// completion, failure, or cancel. Cancelling it trips `Task.isCancelled`
    /// inside `runOCR`, whose guarded state write then no-ops — so an abandoned
    /// read can't surface a result or error over the now-live camera.
    @MainActor private var ocrTask: Task<Void, Never>?

    /// Tracked bounding boxes for the most recent live frame, in Vision-normalized
    /// coordinates (origin bottom-left, components in [0, 1]). The UI overlays
    /// these on top of the preview.
    @MainActor @Published private(set) var liveDetections: [TrackedBox] = []

    /// Rotation (degrees) the live preview layer should apply to its
    /// `AVCaptureConnection` so the on-screen feed matches how the user is
    /// holding the device. Mirrors the angle being applied internally to the
    /// photo and video outputs, which keeps the captured photo, the live
    /// detection coords, and the preview all in the same upright frame.
    @MainActor @Published private(set) var previewRotationAngle: CGFloat = 90

    enum CaptureState: @unchecked Sendable {
        case idle
        case processing(UIImage?)
        /// The structured document for the scanned page plus any website-linking
        /// QR codes. The analysis screen draws the raw photo (`document.image`)
        /// and overlays tappable, color-coded boxes over each interactive text
        /// block and QR code — so no pre-rendered overlay bitmap is carried here.
        case result(VirtualDocument, [DetectedQRCode])
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

    /// Off-main snapshot of `previewRotationAngle` so `sessionQueue` work
    /// (`configureSessionIfNeeded`, `selectCamera`) can re-apply the angle to
    /// freshly-created connections without hopping to the main actor.
    private let rotationLock = NSLock()
    private var _sessionRotationAngle: CGFloat = 90

    /// The video input currently feeding the session. Held so we can detach
    /// it the moment a photo is captured (freezing the preview layer on the
    /// last frame) and re-attach the same instance on reset. Mutated only on
    /// `sessionQueue`.
    ///
    /// Why detach instead of `stopRunning()`: stopping the session is async
    /// and the preview layer can keep painting buffered frames through the
    /// shutdown — the live feed visibly leaks under the processing overlay.
    /// Pulling the input within a `begin/commitConfiguration` block is
    /// synchronous, so frame delivery stops the instant we commit.
    private var activeVideoInput: AVCaptureDeviceInput?

    /// Talks to the self-hosted PaddleOCR-VL deployment on Modal. The endpoint
    /// URL is read from the app bundle's Info.plist (populated from
    /// `secrets.xcconfig` at build time) — see `Secrets.swift`. `nil` when the
    /// endpoint isn't configured; the capture path gates on it being non-nil.
    private let ocrClient = ModalOCRClient.makeDefault()

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
        // Start watching the accelerometer so the photo and preview pipelines
        // can rotate to match how the user is holding the device. Has to run
        // on the main actor — `UIDevice.current` and the notification center
        // both want main.
        Task { @MainActor [weak self] in
            self?.startObservingDeviceOrientation()
        }
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
        if let client = ocrClient {
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

        // Sensor-native quad coords (the videoOutput is intentionally not
        // rotated) line up with the sensor-native pixel buffer below, so the
        // perspective-correction math stays simple; the user-facing
        // orientation is applied via the UIImage tag at encode time.
        rotationLock.lock()
        let angle = _sessionRotationAngle
        rotationLock.unlock()
        let orientation = Self.uiImageOrientation(forVideoRotationAngle: angle)

        let winner = TrackedBox.highlightWinner(in: snapshot)
        let paddedQuad: Quad? = winner.map { box in
            let raw = box.normalizedQuad ?? Quad(rect: box.normalizedRect)
            let padding = YoloEClasses.cropPadding(for: box.classId)
            return raw.expanded(byFactor: padding)
        }

        let imageData: Data? = {
            if let quad = paddedQuad {
                return jpegData(from: pixelBuffer, perspectiveCorrectingTo: quad, orientation: orientation)
            }
            return jpegData(from: pixelBuffer, orientation: orientation)
        }()

        guard let imageData else {
            Task { @MainActor in
                self.captureState = .failed("Failed to encode the captured photo.")
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // If the user hit Cancel in the brief window between the shutter
            // tap and the photo arriving, state is no longer `.processing`.
            // The photo callback already detached the video input to freeze
            // the preview, so re-attach the live camera and skip the read
            // rather than popping a result over it moments later.
            guard case .processing = self.captureState else {
                self.start()
                return
            }
            // Surface the exact bytes headed to OCR — the perspective-corrected
            // crop, or the full uncropped frame when no quad was highlighted —
            // behind the “Reading document…” spinner so the user sees what's
            // being read. `UIImage(data:)` is lazy, so this stays cheap on main.
            self.captureState = .processing(UIImage(data: imageData))
            self.ocrTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.runOCR(on: imageData)
            }
        }
    }

    /// Reset back to live camera. Call from the UI when the user dismisses
    /// the result or error overlay.
    @MainActor
    func resetCaptureState() {
        captureState = .idle
        start()
    }

    /// Abort an in-flight "Reading document…" read and return to the live
    /// camera. Cancelling the task trips `Task.isCancelled` inside `runOCR`,
    /// whose guarded state write then no-ops — so the abandoned read can't pop
    /// a result or error over the camera after the user has moved on.
    @MainActor
    func cancelProcessing() {
        ocrTask?.cancel()
        ocrTask = nil
        resetCaptureState()
    }

    /// Leave the camera flow entirely: abort any in-flight read, drop back to
    /// the idle state, and stop the session so the camera powers down. Called
    /// when the user taps the camera's close button to return to the home
    /// screen — the app launches there with the camera off, and this restores
    /// that state. Unlike `resetCaptureState`, it does *not* restart the
    /// session; entering the camera again from home calls `start()`.
    @MainActor
    func goHome() {
        ocrTask?.cancel()
        ocrTask = nil
        captureState = .idle
        stop()
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
                self.reattachVideoInputIfNeeded()
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

    /// Detaches the active camera input from the session. The preview layer
    /// stops receiving frames immediately and freezes on whatever it last
    /// painted, so the user sees a still image of what they just captured
    /// instead of a live feed bleeding through the processing overlay.
    /// Runs on `sessionQueue`.
    private func detachVideoInput() {
        guard let input = activeVideoInput,
              session.inputs.contains(input) else { return }
        session.beginConfiguration()
        session.removeInput(input)
        session.commitConfiguration()
    }

    /// Re-adds the previously-detached input. No-op if it's still attached
    /// (e.g. cold start, or `start()` called twice). Runs on `sessionQueue`.
    private func reattachVideoInputIfNeeded() {
        guard let input = activeVideoInput,
              !session.inputs.contains(input),
              session.canAddInput(input) else { return }
        session.beginConfiguration()
        session.addInput(input)
        session.commitConfiguration()
        // Re-adding the input gives the outputs new connections — re-stamp
        // rotation so the first frame back isn't sideways.
        applyRotationAngleToConnections()
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
            self.activeVideoInput = newInput

            // Swapping the input gives the photo/video outputs new
            // connections — re-stamp the rotation angle on them so the
            // first frame after the switch isn't sideways.
            self.applyRotationAngleToConnections()

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
        Task { @MainActor in self.captureState = .processing(nil) }

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
        // Outputs are added once and never removed, so an empty list means
        // we haven't set the session up yet. (Inputs come and go — they're
        // detached during photo processing — so they can't gate setup.)
        guard session.outputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        let cameras = discoverCameras()
        let defaultCamera = cameras.first { $0.position == .back } ?? cameras.first

        if let defaultCamera,
           let input = try? AVCaptureDeviceInput(device: defaultCamera),
           session.canAddInput(input) {
            session.addInput(input)
            activeVideoInput = input
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

        // First time the outputs have connections we can stamp; pick up
        // whatever the orientation observer last saw (defaults to portrait
        // if it hasn't fired yet, which matches the initial Published value).
        applyRotationAngleToConnections()

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

    // MARK: - Device orientation

    /// Subscribe to accelerometer-driven orientation notifications and seed
    /// the current angle from `UIDevice.current.orientation`. Without this,
    /// `AVCapturePhoto.pixelBuffer` would always be delivered in the sensor's
    /// native landscape — captured photos would appear sideways/upside-down
    /// any time the user is holding the phone in portrait or rotated 180°.
    @MainActor
    private func startObservingDeviceOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // `queue: nil` means the notification fires on the posting
            // thread; bounce to MainActor so it's safe to read UIDevice.
            Task { @MainActor [weak self] in
                self?.handleDeviceOrientationChange()
            }
        }
        // Pick up the launch-time orientation so the very first frame is
        // already upright, instead of waiting for the user to wiggle the
        // phone for the OS to post a change notification.
        handleDeviceOrientationChange()
    }

    @MainActor
    private func handleDeviceOrientationChange() {
        // `faceUp` / `faceDown` / `unknown` tell us nothing about how the
        // user is holding the device — sticking with the last known angle
        // keeps the camera from snapping back to portrait the moment the
        // user lays the phone on a table mid-composition.
        guard let angle = Self.videoRotationAngle(for: UIDevice.current.orientation) else {
            return
        }
        if previewRotationAngle != angle {
            previewRotationAngle = angle
        }
        rotationLock.lock()
        _sessionRotationAngle = angle
        rotationLock.unlock()
        sessionQueue.async { [weak self] in
            self?.applyRotationAngleToConnections()
        }
    }

    /// Maps a `UIDeviceOrientation` to the `videoRotationAngle` (in degrees)
    /// that AVFoundation needs to deliver upright buffers. Returns nil for
    /// orientations that don't correspond to a user-meaningful "up" — the
    /// caller should hold the previous angle in that case.
    private static func videoRotationAngle(for orientation: UIDeviceOrientation) -> CGFloat? {
        switch orientation {
        case .portrait:           return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft:      return 0
        case .landscapeRight:     return 180
        default:                  return nil
        }
    }

    /// Stamp the current rotation angle onto the photo output's connection so
    /// `photo.metadata` (and `fileDataRepresentation()`, if anything starts
    /// using it) carry the correct EXIF orientation tag at capture time.
    ///
    /// Intentionally *not* applied to the video data output: rotating that
    /// connection rotates the buffer pixels delivered to the detector, but
    /// the metadata-output coord system that the preview overlay's
    /// `layerRectConverted(fromMetadataOutputRect:)` reads is fixed to the
    /// sensor's natural orientation — so a rotated detector frame produces
    /// overlays that drift in the rotation direction. Keep the live frame in
    /// sensor-native and let the preview layer's own connection handle
    /// display rotation; the captured photo gets its upright orientation
    /// baked into the JPEG at encode time (see `uiImageOrientation(for:)`).
    private func applyRotationAngleToConnections() {
        rotationLock.lock()
        let angle = _sessionRotationAngle
        rotationLock.unlock()

        guard let connection = photoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle),
           connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
    }

    /// Map a `videoRotationAngle` (the AVFoundation convention) to the
    /// `UIImage.Orientation` that, when stamped on a UIImage holding sensor-
    /// native pixels, renders / encodes the image upright for the user.
    ///
    /// `photo.pixelBuffer` is *always* delivered in the sensor's natural
    /// landscape orientation regardless of the photo output connection's
    /// rotation, so we have to apply the rotation ourselves — either by
    /// rotating pixels (expensive) or by tagging the UIImage with the
    /// correct orientation (free, and JPEG encoding carries it as EXIF).
    private static func uiImageOrientation(forVideoRotationAngle angle: CGFloat) -> UIImage.Orientation {
        switch Int(angle.rounded()) {
        case 90:  return .right   // device portrait → rotate pixels 90° CW on display
        case 180: return .down    // device landscape-right → 180°
        case 270: return .left    // device portrait upside down → 90° CCW
        default:  return .up      // device landscape-left (sensor native)
        }
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
    ///   2. Submit the upright bytes to the Modal OCR endpoint. It returns
    ///      layout + markdown inline, with bboxes in the coordinate frame of
    ///      the image we uploaded — the Modal path returns no separate
    ///      preprocessed image, so `preprocessedImageURL` is always nil.
    ///   3. Run CRAFT on that *same* uploaded image so the augmentation overlap
    ///      math is coordinate-correct. CRAFT normalizes orientation and flips
    ///      its boxes upright internally, so its boxes land in the same top-left
    ///      frame and the overlap filter compares like with like.
    ///   4. Merge the CRAFT survivors into the layout and render on that image
    ///      (its size matches `pruned.width × pruned.height`, so no rescale at
    ///      draw).
    private func runOCR(on rawJPEG: Data) async {
        guard let ocrClient = ocrClient else {
            await publishFailure("Set the Modal OCR endpoint (MODAL_OCR_URL) in secrets.xcconfig before capturing.")
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

        let filename = "capture-\(UUID().uuidString).jpg"

        do {
            let pages = try await ocrClient.process(
                imageData: prepared.jpeg,
                filename: filename,
                mimeType: "image/jpeg"
            )

            // The user may have hit Cancel while the upload was in flight; bail
            // before touching captureState so the abandoned read can't pop a
            // result over the now-live camera.
            guard !Task.isCancelled else { return }

            guard let page = pages.first else {
                await publishFailure("OCR returned no pages.")
                return
            }
            guard let pruned = page.prunedResult else {
                await publishFailure("OCR response was missing layout data.")
                return
            }

            // CRAFT consumes the same image Baidu's bboxes describe so the
            // overlap filter compares apples to apples. The preprocessed URL is
            // the post-orientation, post-dewarp image; if it's absent (server
            // skipped preprocessing for this page) we fall back to the upright
            // bytes we sent.
            let craftSource = Self.loadCraftSource(
                preprocessedURL: page.preprocessedImageURL,
                fallback: prepared.image
            )
            let craftBoxes = await Self.detectCraftBoxes(in: craftSource)
            let augmented = Self.augment(pruned: pruned, with: craftBoxes)
            let renderSource = craftSource

            // Read every text-class crop through OpenAI (concurrently) BEFORE we
            // render, so the overlay can show the transcriptions in each box.
            // Non-readable text blocks are dropped here; graphics blocks pass
            // through. The spinner stays up for this whole batch — nothing is
            // shown to the user until every reading is back.
            let prepared = await Self.applyOCRReadings(to: augmented, image: renderSource)

            guard !Task.isCancelled else { return }

            // Document build is pure CPU work; offload so this method returns to
            // its caller as fast as possible. On dense pages this is 50-200 ms of
            // layout sort. QR detection rides along on the same hop: it's
            // on-device Vision over the render source (no network — the linked
            // site is only fetched if the user taps the QR later), and only QRs
            // linking to a website are kept. The analysis screen draws the boxes
            // itself over `document.image`, so nothing is rasterized to a bitmap.
            let (document, qrCodes) = await Task.detached(priority: .userInitiated) { () -> (VirtualDocument, [DetectedQRCode]) in
                let document = VirtualDocument.make(from: prepared, image: renderSource)
                let qrCodes = QRCodeDetector.detect(in: renderSource, pageSize: document.pageSize)
                return (document, qrCodes)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.captureState = .result(document, qrCodes)
                self.stop()
                self.ocrTask = nil
            }
        } catch {
            // A cancelled upload surfaces as a thrown error; don't pop it over
            // the camera the user has already returned to.
            guard !Task.isCancelled else { return }
            await publishFailure("OCR error: \(error)")
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

    // MARK: - Per-crop OCR (console diagnostic)

    /// Default per-side crop margin. 0 == crop exactly to the bounding box, so
    /// the image sent to OpenAI is the same size as the box. CRAFT boxes get
    /// their own 10% enlargement upstream (`LayoutAugmentation.craftBoxEnlargement`).
    private static let cropMargin: CGFloat = 0
    /// JPEG quality for the per-crop OpenAI OCR pass. 0.9 keeps small-text
    /// edges crisp; the crops are small, so the byte cost is minor.
    private static let cropJPEGQuality: CGFloat = 0.9

    /// Crops every merged box out of `image` (padded by `margin` per side),
    /// reads the crops concurrently through `OpenAIClient.readText`, matches each
    /// reading back to its box by position (readText preserves input order), and
    /// prints the result. Console-only: never throws, never touches
    /// `captureState`; a missing key, no croppable boxes, or a failed read just
    /// logs and returns.
    /// Whether a block is sent to the OpenAI reader and, once read, rendered as
    /// centered text: prose / titles / headers / footers / footnotes / numbers /
    /// tables / formulas, plus CRAFT boxes (which arrive labeled "text"). Pure
    /// graphics and `unknown` are excluded — see
    /// `VirtualDocument.readableTextLabels`.
    static func isReadableTextBlock(_ block: VirtualDocument.PrunedResult.RawBlock) -> Bool {
        block.isFromCraft
            || VirtualDocument.readableTextLabels.contains(
                VirtualDocument.BlockLabel(apiValue: block.blockLabel))
    }

    /// Crops every text-class block, reads the crops concurrently through
    /// `OpenAIClient.readText`, and returns a new `PrunedResult` where:
    ///   • readable text blocks keep their box and carry the transcription,
    ///   • non-readable text blocks (empty / blurry / irrelevant / failed /
    ///     un-croppable) are dropped entirely, and
    ///   • graphics + `unknown` blocks pass through untouched (colored box, no
    ///     text).
    /// Original block order is preserved. With no API key configured the input
    /// is returned unchanged, so the overlay still shows type-colored boxes.
    private static func applyOCRReadings(
        to pruned: VirtualDocument.PrunedResult,
        image: UIImage,
        margin: CGFloat = cropMargin
    ) async -> VirtualDocument.PrunedResult {
        guard let apiKey = Secrets.openAIAPIKey else {
            print("[crop-read] OPENAI_API_KEY not set — rendering type-colored boxes without text.")
            return pruned
        }

        let textBlocks = pruned.parsingResList.filter(isReadableTextBlock)
        guard !textBlocks.isEmpty else { return pruned }

        let crops = BoundingBoxCropper.croppedJPEGs(
            of: image,
            blocks: textBlocks,
            margin: margin,
            quality: cropJPEGQuality
        )
        // No crop succeeded → no text block can be confirmed readable → drop
        // them all, keeping only the graphics boxes.
        guard !crops.isEmpty else {
            return VirtualDocument.PrunedResult(
                width: pruned.width,
                height: pruned.height,
                parsingResList: pruned.parsingResList.filter { !isReadableTextBlock($0) }
            )
        }

        let client = OpenAIClient(apiKey: apiKey)
        let start = Date()
        let results = await client.readText(in: crops.map(\.jpeg))
        let elapsed = Date().timeIntervalSince(start)

        // Match each readable crop back to its block id → transcription.
        var readableText: [Int: String] = [:]
        for (crop, result) in zip(crops, results) {
            if case .success(let reading) = result, reading.status == .readable {
                let trimmed = reading.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { readableText[crop.block.blockId] = trimmed }
            }
        }

        printReadings(
            boxes: crops.map(\.block),
            results: results,
            totalBlocks: pruned.parsingResList.count,
            elapsed: elapsed
        )

        // Rebuild in original order: readable text blocks carry their reading,
        // non-readable text blocks vanish, everything else passes through.
        let kept = pruned.parsingResList.compactMap { block -> VirtualDocument.PrunedResult.RawBlock? in
            guard isReadableTextBlock(block) else { return block }
            guard let text = readableText[block.blockId] else { return nil }
            return block.replacingContent(text)
        }

        return VirtualDocument.PrunedResult(
            width: pruned.width,
            height: pruned.height,
            parsingResList: kept
        )
    }

    /// Prints a one-line summary plus one line per box matched to its reading.
    /// `boxes[i]` corresponds to `results[i]`.
    private static func printReadings(
        boxes: [VirtualDocument.PrunedResult.RawBlock],
        results: [Result<OpenAIClient.TextReading, Error>],
        totalBlocks: Int,
        elapsed: TimeInterval
    ) {
        var readable = 0, empty = 0, unreadable = 0, irrelevant = 0, failed = 0
        var lines: [String] = []

        for (box, result) in zip(boxes, results) {
            let b = box.blockBbox
            let bbox = b.count >= 4
                ? String(format: "(%.0f,%.0f,%.0f,%.0f)", b[0], b[1], b[2], b[3])
                : "(?)"
            let craft = box.isFromCraft ? " [craft]" : ""
            let head = "  #\(box.blockId) \(box.blockLabel)\(craft) bbox=\(bbox) → "

            switch result {
            case .success(let reading):
                switch reading.status {
                case .readable:
                    readable += 1
                    let text = reading.text.replacingOccurrences(of: "\n", with: " / ")
                    lines.append(head + "readable: \"\(text)\"")
                case .empty:
                    empty += 1
                    lines.append(head + "empty: \(reading.note)")
                case .unreadable:
                    unreadable += 1
                    lines.append(head + "unreadable: \(reading.note)")
                case .irrelevant:
                    irrelevant += 1
                    lines.append(head + "irrelevant: \(reading.note)")
                }
            case .failure(let error):
                failed += 1
                lines.append(head + "FAILURE: \(error.localizedDescription)")
            }
        }

        print(String(
            format: "[crop-read] %d merged boxes → %d crops → %d readable, %d empty, %d unreadable, %d irrelevant, %d failed (%.2fs)",
            totalBlocks, results.count, readable, empty, unreadable, irrelevant, failed, elapsed))
        for line in lines { print(line) }
    }

    @MainActor
    private func publishFailure(_ message: String) {
        ocrTask = nil
        captureState = .failed(message)
    }

    /// Encodes a camera pixel buffer as JPEG data for upload. `orientation`
    /// is stamped on the wrapping `UIImage` so the JPEG carries the matching
    /// EXIF orientation tag — downstream consumers (`UIImage(data:)`, image
    /// viewers, the OCR server) then display / interpret the bytes upright
    /// without us having to physically rotate the pixels here.
    private func jpegData(from pixelBuffer: CVPixelBuffer,
                          orientation: UIImage.Orientation) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
            .jpegData(compressionQuality: 0.9)
    }

    /// Crops + perspective-corrects the pixel buffer to the given Vision-normalized
    /// quad, then JPEG-encodes the rectified result.
    ///
    /// Uses `CIPerspectiveCorrection`, which auto-sizes the output rectangle to
    /// the average length of opposing input sides — so the document's natural
    /// aspect ratio is preserved and features (text, lines, edges) aren't
    /// stretched.
    ///
    /// Orientation is locked to the **detected object**, not to how the phone is
    /// held: `objectOrientedCorners` finds the quad's principal (long) axis and
    /// labels the corners so the rectified crop comes out with that axis
    /// vertical. This is why the result no longer rotates when you tilt the
    /// phone — the old code re-labeled corners by their position in the sensor
    /// frame, so the crop spun with the device and broke entirely for objects
    /// sitting near 45° in the frame. The encoded JPEG carries **no** device
    /// orientation tag (`.up`); any residual 180° / text-up ambiguity is
    /// resolved downstream by PaddleOCR's document-orientation classifier.
    ///
    /// `orientation` is used only for the degenerate-quad fallback below, where
    /// there's no object axis to lock onto and a plain full-frame encode (tagged
    /// with the device orientation) is the best we can do.
    private func jpegData(from pixelBuffer: CVPixelBuffer,
                          perspectiveCorrectingTo quad: Quad,
                          orientation: UIImage.Orientation) -> Data? {
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

        guard let c = Self.objectOrientedCorners(pixelPoints) else {
            // Degenerate (collinear / zero-area) quad — fall back to a plain
            // encode of the full frame.
            return jpegData(from: pixelBuffer, orientation: orientation)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return jpegData(from: pixelBuffer, orientation: orientation)
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: pixelPoints[c.tl]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: pixelPoints[c.tr]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: pixelPoints[c.bl]), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: pixelPoints[c.br]), forKey: "inputBottomRight")

        guard let output = filter.outputImage,
              let cgImage = ciContext.createCGImage(output, from: output.extent) else {
            return nil
        }
        // Already upright in the object's frame — no device-orientation tag.
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
            .jpegData(compressionQuality: 0.9)
    }

    /// Labels a quad's four corners as TL/TR/BR/BL **in the object's own frame**,
    /// returning indices into `p`. The labeling is invariant to how the phone is
    /// held, which is what keeps the rectified crop from rotating as the device
    /// tilts/rolls.
    ///
    /// Method: take the quad's principal (long) axis from the second moments of
    /// its corners, de-rotate the corners so that axis is vertical, then assign
    /// top/bottom by `y` and left/right by `x` in that canonical frame. Doing
    /// the assignment after de-rotation sidesteps the classic "order_points"
    /// (sum/difference) failure, which mislabels — and at exactly 45° collapses —
    /// once a quad is rotated more than 45° in the frame.
    ///
    /// A rectangle's long axis doesn't say which end is "up"; that 180° choice
    /// is resolved (via `rho` below) toward the right-side-up branch for normal
    /// document capture, since the OCR backend no longer re-orients the image.
    /// Returns nil for a degenerate (zero-area) quad.
    private static func objectOrientedCorners(
        _ p: [CGPoint]
    ) -> (tl: Int, tr: Int, br: Int, bl: Int)? {
        guard p.count == 4 else { return nil }

        // Shoelace area — a collinear/zero-area quad has no meaningful axis.
        var signedArea = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            signedArea += Double(a.x * b.y - b.x * a.y)
        }
        guard abs(signedArea) * 0.5 > 1e-6 else { return nil }

        let cx = p.map(\.x).reduce(0, +) / 4
        let cy = p.map(\.y).reduce(0, +) / 4

        // Second moments of the corners about the centroid -> principal angle.
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for q in p {
            let dx = Double(q.x - cx), dy = Double(q.y - cy)
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)   // long-axis angle
        // Bring the long axis vertical. It's a line, so there are two ways up;
        // we use -π/2 (not +π/2) so documents land right-side-up for normal
        // capture. The OCR backend no longer returns a re-oriented image, so
        // this branch choice is final — the +π/2 branch comes out upside down.
        let rho = -Double.pi / 2 - theta
        let cosR = CGFloat(cos(rho)), sinR = CGFloat(sin(rho))

        // De-rotate corners about the centroid into the canonical frame, where
        // the quad is axis-aligned and a plain min/max split is unambiguous.
        let r = p.map { q -> CGPoint in
            let dx = q.x - cx, dy = q.y - cy
            return CGPoint(x: dx * cosR - dy * sinR, y: dx * sinR + dy * cosR)
        }

        let byY = Array(0..<4).sorted { r[$0].y > r[$1].y }
        let top = byY[0..<2], bottom = byY[2..<4]
        guard let tl = top.min(by: { r[$0].x < r[$1].x }),
              let tr = top.max(by: { r[$0].x < r[$1].x }),
              let bl = bottom.min(by: { r[$0].x < r[$1].x }),
              let br = bottom.max(by: { r[$0].x < r[$1].x }),
              Set([tl, tr, br, bl]).count == 4 else { return nil }
        return (tl, tr, br, bl)
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
        // Photo (or error) is in hand — the camera has done its job for this
        // shutter press, so detach the input now. This freezes the preview
        // layer on the last frame for the duration of OCR / the failure
        // overlay; `start()` re-attaches on reset.
        sessionQueue.async { [weak self] in
            self?.detachVideoInput()
        }

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
