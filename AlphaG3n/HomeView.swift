//
//  HomeView.swift
//  AlphaG3n
//
//  The idle landing screen. The app launches here with the camera OFF, just
//  like the LARP render: a hero logo on a dark field. Tapping the logo plays a
//  Nintendo-Switch-style color wipe and hands off to the camera (the caller
//  powers the capture session up). The logo is the screen's single primary
//  action and is the first thing VoiceOver lands on.
//

import SwiftUI

struct HomeView: View {
    /// Invoked once the entry wipe has played; the caller switches to the
    /// camera screen and starts the capture session.
    var onEnter: () -> Void

    @State private var zooming = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// Faint constellation of pixel squares behind the logo. Fixed at init so
    /// they don't jump on every redraw.
    private let stars: [Star] = (0..<36).map { _ in
        Star(
            x: .random(in: 0...1),
            y: .random(in: 0...1),
            size: Double.random(in: 0...1) < 0.85 ? 4 : 7,
            opacity: 0.2 + Double.random(in: 0...0.55)
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(
                    colors: [Color(hex: 0x1A1A20), Color(hex: 0x09090B), Color(hex: 0x050506)],
                    center: UnitPoint(x: 0.5, y: 0.4),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.9
                )
                .ignoresSafeArea()

                starField(in: geo.size)
                    .opacity(zooming ? 0 : 0.5)
                    .accessibilityHidden(true)

                content
                    .opacity(zooming ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: zooming)

                wipeBands(in: geo.size)
            }
        }
        .onAppear { pulse = true }
    }

    // MARK: - Foreground content

    private var content: some View {
        VStack(spacing: 0) {
            // Wordmark
            HStack(spacing: 10) {
                Text("LARP")
                Rectangle().fill(LarpTheme.orange).frame(width: 6, height: 6)
                Text("v0.410.4")
            }
            .font(LarpTheme.mono(11))
            .tracking(3)
            .foregroundStyle(LarpTheme.ink2)
            .padding(.top, 24)
            .accessibilityHidden(true)

            Spacer()

            // Hero logo — the primary action.
            Button(action: beginEnter) {
                Image("larpLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .shadow(color: LarpTheme.red.opacity(0.22), radius: 20, y: 18)
                    .shadow(color: LarpTheme.orange.opacity(0.18), radius: 9, y: 6)
            }
            .buttonStyle(HomeTileButtonStyle())
            .accessibilityLabel("LARP")
            .accessibilityHint("Double tap to open the camera and scan a document")
            .accessibilityAddTraits(.isButton)
            .accessibilitySortPriority(2)

            // Caption
            VStack(spacing: 10) {
                Text("Point & \(Text("Read").foregroundColor(LarpTheme.orange)).")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(LarpTheme.ink0)
                Text("A Layout-Aware Richtext Processor")
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(LarpTheme.ink2)
            }
            .padding(.top, 48)
            .accessibilityHidden(true)

            Spacer()

            // Call to action
            HStack(spacing: 10) {
                Rectangle()
                    .fill(LarpTheme.orange)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 1 : 0.35)
                    .scaleEffect(pulse ? 1.3 : 1)
                    // Gate the looping pulse on VoiceOver as well as Reduce
                    // Motion. A repeatForever animation never lets the view tree
                    // settle, and iOS reacts by re-announcing the focused "LARP"
                    // button on a loop — so a VoiceOver user (who usually has no
                    // Reduce Motion) just hears "LARP… LARP…" every few seconds.
                    // accessibilityHidden on this dot doesn't help; the animation
                    // still churns. Mirrors AnalysisView's `animatesEntry` guard.
                    .animation(
                        (reduceMotion || voiceOverEnabled) ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                        value: pulse
                    )
                Text("TAP LOGO TO BEGIN")
                    .font(LarpTheme.mono(11))
                    .tracking(2.5)
                    .foregroundStyle(LarpTheme.ink1)
            }
            .padding(.bottom, 48)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Decorative layers

    private func starField(in size: CGSize) -> some View {
        ZStack {
            ForEach(Array(stars.enumerated()), id: \.offset) { _, s in
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: s.size, height: s.size)
                    .opacity(s.opacity)
                    .position(x: s.x * size.width, y: s.y * size.height)
            }
        }
    }

    /// Three staggered color bands that sweep down across the screen on enter.
    private func wipeBands(in size: CGSize) -> some View {
        let h = size.height * 1.4
        let bands: [Color] = [LarpTheme.orange, LarpTheme.red, LarpTheme.bg0]
        return ZStack {
            ForEach(Array(bands.enumerated()), id: \.offset) { i, color in
                Rectangle()
                    .fill(color)
                    .frame(width: size.width * 1.1, height: h)
                    .offset(y: zooming ? h : -h)
                    .animation(
                        .timingCurve(0.46, 0.03, 0.52, 0.96, duration: 0.72)
                            .delay(Double(i) * 0.11),
                        value: zooming
                    )
            }
        }
        // The bands are deliberately oversized (1.1×W, 1.4×H) for full sweep
        // coverage. Clamp this layer's *layout* footprint to the screen so it
        // can't inflate the parent ZStack in `body` — otherwise the ZStack grows
        // past `geo.size`, GeometryReader pins it top-leading, and `content` ends
        // up centered within the inflated bounds (shifted right ~5%W, down ~20%H).
        // The bands still draw oversized; they just no longer drive layout.
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func beginEnter() {
        if reduceMotion {
            onEnter()
            return
        }
        zooming = true
        // Let the bands sweep, then hand off to the camera.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) {
            onEnter()
        }
    }
}

private struct Star {
    let x: Double
    let y: Double
    let size: CGFloat
    let opacity: Double
}

/// Subtle press feedback on the hero tile (scale down on touch), matching the
/// mockup's `:active` transform.
private struct HomeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
