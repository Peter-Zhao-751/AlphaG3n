//
//  ContentView.swift
//  AlphaG3n
//
//  Top-level flow. The app launches at the Home screen with the camera OFF;
//  tapping the LARP logo powers up the capture session and drops into the
//  camera. From there the capture pipeline's state drives which screen shows:
//  the live viewfinder, the "analyzing" sweep, the analysis result, or an
//  error. The camera's close button returns Home and powers the camera back
//  down.
//
//  The LARP visual language lives in LarpTheme / HomeView / AnalysisView /
//  SentenceListView; this file owns the orchestration plus the camera,
//  processing and failure chrome.
//

import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    /// The app opens idle on the Home screen with the camera off. Leaving Home
    /// starts the session; the camera's close button (`goHome`) stops it.
    @State private var atHome = true

    var body: some View {
        ZStack {
            if atHome {
                HomeView(onEnter: enterCamera)
                    .transition(.opacity)
            } else {
                cameraFlow
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: atHome)
        // The session is owned by the camera flow, not the app's lifetime; make
        // sure it's stopped if this view ever goes away while in-camera.
        .onDisappear { camera.stop() }
    }

    private func enterCamera() {
        atHome = false
        camera.start()
    }

    private func goHome() {
        camera.goHome()
        atHome = true
        // Quitting the camera should land VoiceOver on Home's LARP button (its
        // only control), not nowhere. Once the swap settles, a screen-changed
        // post sends focus to the new screen's first element.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    private var cameraFlow: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                detections: camera.liveDetections,
                rotationAngle: camera.previewRotationAngle
            )
            .ignoresSafeArea()

            overlay
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch camera.captureState {
        case .idle:
            CameraControls(onClose: goHome, onCapture: camera.capturePhoto)
        case .processing(let image):
            ProcessingOverlay(image: image, onCancel: camera.cancelProcessing)
        case .result(let document, let qrCodes):
            AnalysisView(
                document: document,
                qrCodes: qrCodes,
                onRecapture: camera.resetCaptureState
            )
        case .failed(let message):
            FailureOverlay(message: message, onDismiss: camera.resetCaptureState)
        }
    }
}

// MARK: - Camera controls (live viewfinder chrome)

/// The idle camera screen overlaid on the live preview: a decorative scanning
/// reticle, a close button (top-left) back to Home, a hint line, and the
/// full-width Capture bar. The close button and Capture bar carry the
/// VoiceOver labels; everything else is decorative and hidden.
private struct CameraControls: View {
    var onClose: () -> Void
    var onCapture: () -> Void

    var body: some View {
        ZStack {
            //CameraReticle()

            VStack(spacing: 0) {
                HStack {
                    LarpIconButton(
                        systemImage: "xmark",
                        accessibilityLabel: "Close camera",
                        accessibilityHint: "Returns to the home screen",
                        scale: 1.5,
                        action: onClose
                    )
                    // Held out of VoiceOver as the viewfinder appears so focus
                    // lands on Capture below, not this top-left Close button.
                    .voiceOverDeferredEntry()
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 22) {
                    LarpHintLine(text: "Hold still — auto-detecting layout")
                    LarpCaptureBar(action: onCapture)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 44)
            }
        }
    }
}

/// Brand focus reticle — orange corner brackets, pixel ticks and a "SCANNING"
/// label that breathe gently in the center of the frame. Purely decorative.
private struct CameraReticle: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Gate looping motion on VoiceOver too, not just Reduce Motion: a
    // repeatForever animation never lets the view tree settle, which makes
    // VoiceOver re-announce the focused element on a loop (see HomeView).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        ZStack {
            LCorner().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            LCorner().rotationEffect(.degrees(90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            LCorner().rotationEffect(.degrees(180))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            LCorner().rotationEffect(.degrees(270))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            Text("SCANNING")
                .font(LarpTheme.mono(10))
                .tracking(2)
                .foregroundStyle(LarpTheme.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(y: -22)
        }
        .frame(width: 220, height: 220)
        .overlay(PixelCorners(color: LarpTheme.orange, size: 6))
        .scaleEffect(breathe ? 1.04 : 1)
        .animation(
            (reduceMotion || voiceOverEnabled) ? nil : .easeInOut(duration: 3.6).repeatForever(autoreverses: true),
            value: breathe
        )
        .onAppear { breathe = true }
        .accessibilityHidden(true)
    }
}

/// One top-left focus bracket (two short orange rules). Rotated by the reticle
/// to make the other three corners.
private struct LCorner: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().frame(width: 22, height: 2)
            Rectangle().frame(width: 2, height: 22)
        }
        .frame(width: 22, height: 22, alignment: .topLeading)
        .foregroundStyle(LarpTheme.orange)
    }
}

// MARK: - Processing overlay

/// Shown while OCR runs. The captured frame sits darkened behind an orange
/// scan line that sweeps up and down, with an "Analyzing layout" caption and a
/// top-left Cancel button that aborts the read and returns to the camera.
private struct ProcessingOverlay: View {
    let image: UIImage?
    let onCancel: () -> Void

    // Reduce Motion is the only switch now: it parks the scan line and freezes
    // the caption dots. VoiceOver no longer gates them — they're driven by Core
    // Animation (see `ProcessingScanLine`), which keeps the perpetual motion off
    // the SwiftUI/accessibility tree so it can't disturb VoiceOver.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LarpTheme.bg0.ignoresSafeArea()

            if let image {
                // Darkened backdrop only; the caption and Cancel button carry
                // the accessibility here. `InertPhoto` keeps it inert to touch
                // *and* VoiceOver at the UIKit layer (see its definition) — the
                // result screen uses the same backdrop. Dim + desaturation are
                // unchanged; the fill frame mirrors the old `scaledToFit`.
                InertPhoto(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .brightness(-0.25)
                    .saturation(0.7)
                Color.black.opacity(0.35).ignoresSafeArea()
            }

            ProcessingScanLine(animated: !reduceMotion)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Caption near the bottom.
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    ProcessingDot(animated: !reduceMotion).frame(width: 6, height: 6)
                    Text("ANALYZING LAYOUT")
                        .font(LarpTheme.mono(10.5))
                        .tracking(3)
                        .foregroundStyle(LarpTheme.orange)
                    ProcessingDot(animated: !reduceMotion).frame(width: 6, height: 6)
                }
                .shadow(color: .black.opacity(0.5), radius: 8)
                .padding(.bottom, 88)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Analyzing the document layout, please wait.")

            // Cancel.
            VStack {
                HStack {
                    LarpIconButton(
                        systemImage: "xmark",
                        accessibilityLabel: "Cancel",
                        accessibilityHint: "Stops reading the document and returns to the camera",
                        action: onCancel
                    )
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                Spacer()
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Core-Animation scan motion (VoiceOver-safe)

/// The orange band that sweeps up and down over the darkened capture while OCR
/// runs. Backed by Core Animation so the perpetual motion lives on the render
/// server and never re-renders the SwiftUI view tree — which is what let a
/// SwiftUI `repeatForever` animation keep the tree from settling and make
/// VoiceOver re-announce the "Analyzing layout" caption on a loop. It can
/// therefore run with VoiceOver active. Purely decorative → out of the a11y tree.
private struct ProcessingScanLine: UIViewRepresentable {
    /// False under Reduce Motion → the band parks off-screen (no sweep).
    var animated: Bool

    func makeUIView(context: Context) -> ScanLineUIView {
        let view = ScanLineUIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: ScanLineUIView, context: Context) {
        uiView.animating = animated
    }
}

/// UIView backing `ProcessingScanLine`: a full-width gradient band whose
/// vertical position Core Animation drives from just above the top edge to just
/// below the bottom and back, easing in/out, forever.
private final class ScanLineUIView: UIView {
    private let band = CAGradientLayer()
    private static let bandHeight: CGFloat = 130
    private static let key = "scanSweep"

    var animating = false {
        didSet { if animating != oldValue { reseat() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let orange = UIColor(red: 1, green: 177 / 255, blue: 74 / 255, alpha: 1) // #FFB14A
        band.colors = [
            orange.withAlphaComponent(0).cgColor,
            orange.withAlphaComponent(0.35).cgColor,
            UIColor.white.withAlphaComponent(0.55).cgColor,
            orange.withAlphaComponent(0.35).cgColor,
            orange.withAlphaComponent(0).cgColor,
        ]
        band.locations = [0, 0.4, 0.5, 0.6, 1]
        band.startPoint = CGPoint(x: 0.5, y: 0)
        band.endPoint = CGPoint(x: 0.5, y: 1)
        band.compositingFilter = "screenBlendMode" // ≈ SwiftUI .blendMode(.screen)
        layer.addSublayer(band)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: Self.bandHeight)
        band.position.x = bounds.midX
        CATransaction.commit()
        reseat() // re-fit the sweep to the current height (first layout, rotation)
    }

    /// (Re)installs or removes the perpetual sweep for the current state/bounds.
    private func reseat() {
        band.removeAnimation(forKey: Self.key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.position.y = -Self.bandHeight / 2 // parked just above the top edge
        CATransaction.commit()
        guard animating, bounds.height > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = -Self.bandHeight / 2
        sweep.toValue = bounds.height + Self.bandHeight / 2
        sweep.duration = 1.4
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(sweep, forKey: Self.key)
    }
}

/// A small orange square that pulses while OCR runs — the dots flanking the
/// "Analyzing layout" caption. Core-Animation-driven for the same reason as
/// `ProcessingScanLine`, so it can pulse with VoiceOver active without keeping
/// the SwiftUI tree from settling. Decorative; hidden from accessibility.
private struct ProcessingDot: UIViewRepresentable {
    /// False under Reduce Motion → the dot holds steady at full opacity.
    var animated: Bool

    func makeUIView(context: Context) -> DotUIView {
        let view = DotUIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: DotUIView, context: Context) {
        uiView.animating = animated
    }
}

/// UIView backing `ProcessingDot`: a solid orange square whose opacity Core
/// Animation pulses between 0.3 and 1, easing in/out, forever.
private final class DotUIView: UIView {
    private static let key = "blink"

    var animating = false {
        didSet { if animating != oldValue { reseat() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 1, green: 177 / 255, blue: 74 / 255, alpha: 1) // #FFB14A
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func reseat() {
        layer.removeAnimation(forKey: Self.key)
        layer.opacity = 1
        guard animating else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 0.3
        blink.toValue = 1.0
        blink.duration = 0.9
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(blink, forKey: Self.key)
    }
}

// MARK: - Failure overlay

/// Shown when a read fails. A back bar returns to the camera, with the error
/// spelled out below for VoiceOver and sighted users alike.
private struct FailureOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            LarpTheme.bg0.ignoresSafeArea()

            VStack(spacing: 0) {
                LarpBackBar(
                    title: "Back",
                    accessibilityHint: "Closes this message and returns to the camera",
                    action: onDismiss
                )
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(LarpTheme.orange)
                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(LarpTheme.ink0)
                        .padding(.horizontal, 32)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message)
                Spacer()
            }
        }
        .transition(.opacity)
    }
}

#Preview {
    ContentView()
}
