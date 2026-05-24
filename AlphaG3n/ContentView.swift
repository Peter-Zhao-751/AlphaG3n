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

    /// Pulls VoiceOver onto the Capture button whenever the live viewfinder
    /// appears — most importantly when returning here from the analysis screen
    /// (a state-driven swap that otherwise leaves focus stranded), but also on
    /// first entry, where Capture is the screen's primary action.
    @AccessibilityFocusState private var captureFocused: Bool

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
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 22) {
                    LarpHintLine(text: "Hold still — auto-detecting layout")
                    LarpCaptureBar(action: onCapture)
                        .accessibilityFocused($captureFocused)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 44)
            }
        }
        // The brief delay lets the swap from the analysis screen settle so
        // VoiceOver doesn't re-home onto the Close button (top-left) after we
        // move focus — the same timing the reader/summary screens use.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                captureFocused = true
            }
        }
    }
}

/// Brand focus reticle — orange corner brackets, pixel ticks and a "SCANNING"
/// label that breathe gently in the center of the frame. Purely decorative.
private struct CameraReticle: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            reduceMotion ? nil : .easeInOut(duration: 3.6).repeatForever(autoreverses: true),
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

    @State private var sweepDown = false
    @State private var blink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LarpTheme.bg0.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
                    .brightness(-0.25)
                    .saturation(0.7)
                    // Darkened backdrop only; same inert pairing as the result
                    // screen — touch off, and out of VoiceOver (the caption and
                    // Cancel button carry the accessibility here instead).
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Color.black.opacity(0.35).ignoresSafeArea()
            }

            sweep

            // Caption near the bottom.
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    procDot
                    Text("ANALYZING LAYOUT")
                        .font(LarpTheme.mono(10.5))
                        .tracking(3)
                        .foregroundStyle(LarpTheme.orange)
                    procDot
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
        .onAppear {
            sweepDown = true
            blink = true
        }
    }

    private var sweep: some View {
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: LarpTheme.orange.opacity(0), location: 0),
                    .init(color: LarpTheme.orange.opacity(0.35), location: 0.4),
                    .init(color: .white.opacity(0.55), location: 0.5),
                    .init(color: LarpTheme.orange.opacity(0.35), location: 0.6),
                    .init(color: LarpTheme.orange.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 130)
            .offset(y: sweepDown ? geo.size.height : -130)
            .blendMode(.screen)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: sweepDown
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var procDot: some View {
        Rectangle()
            .fill(LarpTheme.orange)
            .frame(width: 6, height: 6)
            .opacity(blink ? 1 : 0.3)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: blink
            )
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
