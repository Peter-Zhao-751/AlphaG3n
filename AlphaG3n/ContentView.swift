//
//  ContentView.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                detections: camera.liveDetections,
                rotationAngle: camera.previewRotationAngle
            )
                .ignoresSafeArea()

            VStack {
                //cameraPicker
                Spacer()
                shutterButton
            }
            .padding()

            overlay
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch camera.captureState {
        case .idle:
            EmptyView()
        case .processing(let image):
            processingOverlay(image: image)
        case .result(let image, let document, let qrCodes):
            ResultOverlay(image: image, document: document, qrCodes: qrCodes) { camera.resetCaptureState() }
        case .failed(let message):
            FailureOverlay(message: message) { camera.resetCaptureState() }
        }
    }

    @ViewBuilder
    private func processingOverlay(image: UIImage?) -> some View {
        ZStack {
            if let image {
                // The captured frame headed to OCR — the perspective-corrected
                // crop, or the full uncropped frame in the fallback — sits behind
                // the spinner so the user sees exactly what's being read.
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea(edges: .bottom)
                // Dim scrim keeps the white spinner + text legible over any image.
                Color.black.opacity(0.45).ignoresSafeArea()
            } else {
                Color.black.opacity(0.55).ignoresSafeArea()
            }
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
                Text("Reading document…")
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            TopActionBar(
                title: "Cancel",
                tint: .red,
                accessibilityHint: "Stops reading the document and returns to the camera"
            ) {
                camera.cancelProcessing()
            }
        }
        .transition(.opacity)
    }

    /// Lets you pick among the cameras the device actually has.
    /// Only shown when there's more than one to choose from.
    @ViewBuilder
    private var cameraPicker: some View {
        if camera.availableCameras.count > 1 {
            Picker("Camera", selection: cameraSelection) {
                ForEach(camera.availableCameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device as AVCaptureDevice?)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var cameraSelection: Binding<AVCaptureDevice?> {
        Binding(
            get: { camera.selectedCamera },
            set: { device in if let device { camera.selectCamera(device) } }
        )
    }

    private var shutterButton: some View {
        Button(action: camera.capturePhoto) {
            Circle()
                .fill(.white)
                .frame(width: 70, height: 70)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.6), lineWidth: 4)
                        .padding(4)
                )
        }
        .disabled(!camera.captureState.isIdle)
        .opacity(camera.captureState.isIdle ? 1 : 0.4)
    }
}

// MARK: - Result / failure overlays

private struct ResultOverlay: View {
    let image: UIImage
    /// The structured document behind `image`, used to place tap targets over
    /// text blocks. The rendered image alone is a flat bitmap with nothing to hit.
    let document: VirtualDocument
    /// Website-linking QR codes found on the page. Each becomes a tap target —
    /// like a multi-sentence text block — that opens a spoken website summary.
    let qrCodes: [DetectedQRCode]
    let onDismiss: () -> Void

    /// What the user drilled into over the document: a text block's sentences or
    /// a QR code's website summary. Mutually exclusive; `nil` shows the document.
    @State private var drilldown: Drilldown?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                // Invisible buttons sit exactly over each interactive region —
                // multi-sentence text blocks and website QR codes. The overlay's
                // GeometryReader is sized to the fitted image, so a region's
                // page-space rect maps in with a plain axis scale and no
                // letterbox offset. Real Buttons, so a sighted tap and a
                // VoiceOver double-tap both open the matching screen.
                .overlay {
                    GeometryReader { geo in
                        ForEach(interactiveParts) { part in
                            let r = screenRect(forPageRect: part.bbox, in: geo.size)
                            Button { drilldown = .reading(part) } label: {
                                Color.clear.contentShape(Rectangle())
                            }
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .accessibilityLabel(part.content)
                            .accessibilityHint("Double tap to read sentence by sentence")
                        }

                        // QR codes that link to a website. Tapping fetches and
                        // summarizes the linked page (see WebSummaryView); the
                        // site is only visited on this tap, never at scan time.
                        ForEach(qrCodes) { qr in
                            let r = screenRect(forPageRect: qr.pageRect, in: geo.size)
                            Button { drilldown = .summary(qr) } label: {
                                Color.clear.contentShape(Rectangle())
                            }
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .accessibilityLabel("QR code linking to \(qr.url.host ?? "a website")")
                            .accessibilityHint("Double tap to open a summary of the linked website")
                        }
                    }
                }
                .ignoresSafeArea(edges: .bottom)

            TopActionBar(
                title: "Done",
                accessibilityHint: "Closes the scanned document and returns to the camera",
                action: onDismiss
            )
        }
        .transition(.opacity)
        .fullScreenCover(item: $drilldown) { item in
            switch item {
            case .reading(let part):
                SentenceReadingView(
                    sentences: SentenceSplitter.sentences(in: part.content)
                ) { drilldown = nil }
            case .summary(let qr):
                WebSummaryView(url: qr.url) { drilldown = nil }
            }
        }
    }

    /// Text blocks worth drilling into: real text parts whose transcription holds
    /// at least two sentences. Single-sentence blocks, titles, page numbers, and
    /// image parts stay non-interactive so there are no dead-end taps.
    private var interactiveParts: [VirtualDocument.Part] {
        document.parts.filter { part in
            guard case .text = part else { return false }
            return SentenceSplitter.hasMultipleSentences(in: part.content)
        }
    }

    /// A page-space rect in the fitted image's own coordinates. The overlay
    /// GeometryReader is already aligned to the displayed image, so this is just
    /// the page→view axis scale that `VirtualDocument.render()` applies. Shared
    /// by text-block bboxes and QR-code page rects, which live in the same frame.
    private func screenRect(forPageRect b: CGRect, in size: CGSize) -> CGRect {
        let page = document.pageSize
        guard page.width > 0, page.height > 0 else { return .zero }
        let sx = size.width / page.width
        let sy = size.height / page.height
        return CGRect(x: b.minX * sx, y: b.minY * sy, width: b.width * sx, height: b.height * sy)
    }
}

/// A region the user can drill into from the result screen. Mutually exclusive,
/// so a single full-screen cover binding drives both the sentence reader and the
/// QR website summary.
private enum Drilldown: Identifiable {
    case reading(VirtualDocument.Part)
    case summary(DetectedQRCode)

    var id: String {
        switch self {
        case .reading(let part): return "reading-\(part.id)"
        case .summary(let qr):   return "summary-\(qr.id)"
        }
    }
}

// MARK: - Sentence-by-sentence reading

/// Full-screen reading view for one text block: its transcription broken into
/// sentences, each its own large, VoiceOver-focusable element so a blind user
/// can swipe through them one at a time. Presented from a tapped block on the
/// result screen; shown only for blocks with two or more sentences.
private struct SentenceReadingView: View {
    let sentences: [String]
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                        Text(sentence)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            // One element per sentence: VoiceOver reads the text
                            // and announces position so the user knows where they
                            // are in the block.
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(sentence)
                            .accessibilityHint("Sentence \(index + 1) of \(sentences.count)")
                    }
                }
                .padding(.horizontal, 20)
                // Clear the floating top bar; breathe at the bottom.
                .padding(.top, 96)
                .padding(.bottom, 40)
            }

            TopActionBar(
                title: "Done",
                accessibilityHint: "Closes sentence reading and returns to the document",
                action: onDone
            )
        }
    }
}

private struct FailureOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
            }
            .padding()

            TopActionBar(
                title: "Dismiss",
                tint: .red,
                accessibilityHint: "Closes this message and returns to the camera",
                action: onDismiss
            )
        }
        .transition(.opacity)
    }
}

// MARK: - Accessible top action bar

/// A rounded, pill-shaped button that floats near the top of an overlay — just
/// below the Dynamic Island and inset from the screen edges. Long and thin so
/// it reads as an ordinary button, but still a wide, easy tap target wired for
/// VoiceOver. Shared by the processing, result, and failure overlays — and the
/// QR website-summary cover (WebSummaryView) — so the primary action sits in
/// the same place on every screen.
struct TopActionBar: View {
    let title: String
    /// Leading SF Symbol. Defaults to the familiar close glyph.
    var systemImage: String = "xmark"
    /// Button fill. Cosmetic only — VoiceOver never reads color.
    var tint: Color = .accentColor
    /// Spoken description of what tapping does.
    var accessibilityHint: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(tint, in: Capsule())
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(.isButton)
            // Land VoiceOver focus here first — it's the screen's primary action.
            .accessibilitySortPriority(1)

            Spacer()
        }
        // Inset from the edges and nudged down so the pill sits just under the
        // Dynamic Island rather than running to the top/side edges.
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

private extension CameraManager.CaptureState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

#Preview {
    ContentView()
}
