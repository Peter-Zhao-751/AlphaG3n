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
        case .processing:
            processingOverlay
        case .result(let image):
            ResultOverlay(image: image) { camera.resetCaptureState() }
        case .failed(let message):
            FailureOverlay(message: message) { camera.resetCaptureState() }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
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
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea(edges: .bottom)

            TopActionBar(
                title: "Done",
                accessibilityHint: "Closes the scanned document and returns to the camera",
                action: onDismiss
            )
        }
        .transition(.opacity)
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
/// VoiceOver. Shared by the processing, result, and failure overlays so the
/// primary action sits in the same place on every screen.
private struct TopActionBar: View {
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
