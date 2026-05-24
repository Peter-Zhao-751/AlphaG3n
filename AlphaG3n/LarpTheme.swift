//
//  LarpTheme.swift
//  AlphaG3n
//
//  Design tokens + shared UI building blocks for the LARP visual language
//  (ported from `LARP App Flow.html`). Colors, the orange→red brand gradient,
//  monospace accent fonts, and the reusable chrome — the icon button, the
//  wide back/recapture bar, the full-width Capture bar, and the pixel-corner
//  motif — that every screen shares so the look stays consistent.
//
//  Visuals are for sighted / low-vision users; the accessibility layer
//  (labels, hints, traits, focus order, ≥44pt targets) is carried right
//  alongside them so VoiceOver users lose nothing.
//

import SwiftUI

// MARK: - Color tokens

extension Color {
    /// Builds a color from a packed 0xRRGGBB literal.
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum LarpTheme {
    // Surfaces
    static let bg0 = Color(hex: 0x0B0B0D)
    static let bg1 = Color(hex: 0x131316)
    static let bg2 = Color(hex: 0x1B1B1F)
    static let bg3 = Color(hex: 0x25252A)
    static let line = Color.white.opacity(0.08)
    static let line2 = Color.white.opacity(0.14)

    // Ink
    static let ink0 = Color(hex: 0xF6F6F7)
    static let ink1 = Color(hex: 0xC9C9CE)
    static let ink2 = Color(hex: 0x8B8B92)
    static let ink3 = Color(hex: 0x5A5A60)

    // Brand
    static let orange = Color(hex: 0xFFB14A)
    static let orangeDeep = Color(hex: 0xF39520)
    static let red = Color(hex: 0xFF6347)
    static let redDeep = Color(hex: 0xE8482B)

    /// Signature diagonal fill used on the Capture bar and primary actions.
    static let brandGradient = LinearGradient(
        colors: [orange, red],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Monospace accent face (SF Mono) for the uppercase, letter-spaced labels
    /// that pepper the design. The mockup names JetBrains Mono with SF Mono as
    /// its fallback; we use the fallback so nothing has to be bundled.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Pixel corner motif

/// Four small squares pinned just outside the corners of the parent frame —
/// the brand "pixel tick" detail on reticles and chunk boxes. Purely
/// decorative, so it's hidden from VoiceOver.
struct PixelCorners: View {
    var color: Color
    var size: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let o = size / 2
            ForEach(0..<4, id: \.self) { i in
                let x = (i % 2 == 0) ? -o : w + o - size
                let y = (i < 2) ? -o : h + o - size
                Rectangle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .offset(x: x, y: y)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Icon button (rounded blur square)

/// The small rounded, blurred-background icon button used in the camera top
/// bar (e.g. the close X). 44pt so it's a comfortable VoiceOver target even
/// though the mockup draws it at 40.
struct LarpIconButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var accessibilityHint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Wide back / recapture bar

/// Full-width pill placed at the top of a screen (in normal flow, above the
/// content): a back chevron plus a mono, letter-spaced title. Used for
/// Recapture (analysis), Back to scan (reader / summary) and Back (failure),
/// so the primary back action sits in the same place everywhere and lands
/// VoiceOver focus first.
struct LarpBackBar: View {
    var title: String
    var accessibilityHint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .bold))
                Text(title.uppercased())
                    .font(LarpTheme.mono(12, weight: .medium))
                    .tracking(2.5)
            }
            .foregroundStyle(LarpTheme.ink0)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(LarpTheme.bg2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(LarpTheme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilitySortPriority(1)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Capture bar

/// The full-width gradient Capture button — the camera's shutter. Pixel-dot
/// glyphs flank the label, matching the mockup. Disabled (dimmed) while a
/// capture is already in flight.
struct LarpCaptureBar: View {
    var isEnabled: Bool = true
    var action: () -> Void

    private var glyph: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Rectangle().frame(width: 6, height: 6)
                Rectangle().frame(width: 6, height: 6)
            }
            GridRow {
                Rectangle().frame(width: 6, height: 6)
                Rectangle().frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(LarpTheme.bg0)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                glyph
                Text("CAPTURE")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(3)
                glyph
            }
            .foregroundStyle(LarpTheme.bg0)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(LarpTheme.brandGradient, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
                    .blendMode(.overlay)
            )
            .shadow(color: LarpTheme.red.opacity(0.30), radius: 15, y: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel("Capture")
        .accessibilityHint("Double tap to scan the document in view")
        .accessibilityAddTraits(.isButton)
        .accessibilitySortPriority(1)
    }
}

// MARK: - Mono caption line

/// A centered, mono, letter-spaced hint line flanked by thin rules — the
/// "Hold still…" style caption. Decorative chrome, hidden from VoiceOver by
/// default (callers that want it spoken pass `spoken: true`).
struct LarpHintLine: View {
    var text: String
    var spoken: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.white.opacity(0.4)).frame(width: 26, height: 1)
            Text(text.uppercased())
                .font(LarpTheme.mono(10))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.7))
            Rectangle().fill(.white.opacity(0.4)).frame(width: 26, height: 1)
        }
        .accessibilityHidden(!spoken)
        .accessibilityLabel(spoken ? text : "")
    }
}
