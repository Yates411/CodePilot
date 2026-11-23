import AppKit
import CodePilotCore
import SwiftUI

/// Unified Braun / Teenage Engineering "Warm Ceramic & Obsidian OLED" design tokens.
enum BrandPalette {
    static let braunOrange = Color(red: 1.0, green: 0.353, blue: 0.122)      // #FF5A1F
    static let signalRed = Color(red: 1.0, green: 0.271, blue: 0.227)        // #FF453A
    static let telemetryCyan = Color(red: 0.196, green: 0.824, blue: 1.0)    // #32D2FF
    static let telemetryBlueLight = Color(red: 0.0, green: 0.478, blue: 1.0) // #007AFF
    static let emeraldGreen = Color(red: 0.188, green: 0.820, blue: 0.345)   // #30D158
    static let amberOrange = Color(red: 1.0, green: 0.624, blue: 0.039)      // #FF9F0A

    static func runningAccent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? telemetryCyan : telemetryBlueLight
    }

    static func chassisGradient(for scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.153, green: 0.157, blue: 0.176),
                    Color(red: 0.106, green: 0.110, blue: 0.125)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.973, green: 0.965, blue: 0.945),
                Color(red: 0.925, green: 0.910, blue: 0.875)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func surfaceTint(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.11, green: 0.115, blue: 0.13).opacity(0.92)
            : Color(red: 0.965, green: 0.957, blue: 0.937).opacity(0.94)
    }

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.05)
            : Color.white
    }

    static func cardBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    static func oledBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.031, green: 0.035, blue: 0.043)
            : Color(red: 0.047, green: 0.051, blue: 0.063)
    }
}

/// Precision linear vector status glyph (Linear / Apple HIG inspired, zero plastic dots or emoji).
struct StatusGlyphView: View {
    let status: TaskStatus
    var size: CGFloat = 14
    var animateRunning: Bool = true
    var overrideColor: Color? = nil

    private var color: Color {
        if let overrideColor { return overrideColor }
        switch status {
        case .waitingUser: return BrandPalette.braunOrange
        case .running: return BrandPalette.telemetryCyan
        case .completed: return BrandPalette.emeraldGreen
        case .error: return BrandPalette.amberOrange
        }
    }

    var body: some View {
        switch status {
        case .waitingUser:
            WaitingRingGlyph(size: size, color: color)
        case .running:
            RunningOrbitGlyph(size: size, color: color, animate: animateRunning)
        case .completed:
            CompletedCheckGlyph(size: size, color: color)
        case .error:
            ErrorTriangleGlyph(size: size, color: color)
        }
    }
}

struct WaitingRingGlyph: View {
    var size: CGFloat = 14
    var color: Color = BrandPalette.braunOrange

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, lineWidth: max(1.2, size * 0.11))
            VStack(spacing: max(1.0, size * 0.11)) {
                Capsule()
                    .fill(color)
                    .frame(width: max(1.4, size * 0.12), height: size * 0.30)
                Circle()
                    .fill(color)
                    .frame(width: max(1.5, size * 0.13), height: max(1.5, size * 0.13))
            }
        }
        .frame(width: size, height: size)
    }
}

struct RunningOrbitGlyph: View {
    var size: CGFloat = 14
    var color: Color = BrandPalette.telemetryCyan
    var animate: Bool = true

    private var shouldSpin: Bool {
        animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        if shouldSpin {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let angle = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4) * 360.0
                orbitBody(angle: angle)
            }
        } else {
            orbitBody(angle: 0)
        }
    }

    private func orbitBody(angle: Double) -> some View {
        let lw = max(1.2, size * 0.115)
        return ZStack {
            Circle()
                .strokeBorder(color.opacity(0.24), lineWidth: lw)
            Circle()
                .trim(from: 0.0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(angle - 90))
        }
        .frame(width: size, height: size)
    }
}

struct CompletedCheckGlyph: View {
    var size: CGFloat = 14
    var color: Color = BrandPalette.emeraldGreen

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
            Circle()
                .strokeBorder(color, lineWidth: max(1.1, size * 0.10))
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

struct ErrorTriangleGlyph: View {
    var size: CGFloat = 14
    var color: Color = BrandPalette.amberOrange

    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: size * 0.85, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

struct PowerArcGlyphView: View {
    var size: CGFloat = 13
    var color: Color = BrandPalette.emeraldGreen

    var body: some View {
        Image(systemName: "power")
            .font(.system(size: size * 0.88, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

struct AllGridGlyphView: View {
    var size: CGFloat = 12
    var color: Color = .primary

    var body: some View {
        Image(systemName: "square.grid.2x2.fill")
            .font(.system(size: size * 0.85, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

/// Signature Braun 4x2 acoustic grille dots.
struct BraunSpeakerGrilleView: View {
    var columns: Int = 4
    var rows: Int = 2
    var dotSize: CGFloat = 3.2
    var spacing: CGFloat = 3.5

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { _ in
                        Circle()
                            .fill(Color.primary.opacity(0.24))
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
    }
}

/// Legacy small LED dot retained for subtle inline indicators (e.g. Onboarding / Settings ready dot).
struct LEDDotView: View {
    let color: Color
    var size: CGFloat = 8
    var breathing: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Miniature Warm Ceramic Precision Instrument App Icon for in-app branding headers.
struct CodePilotAppMarkView: View {
    var size: CGFloat = 24

    var body: some View {
        let scale = size / 256.0
        ZStack {
            RoundedRectangle(cornerRadius: 56 * scale, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.985, green: 0.980, blue: 0.968),
                            Color(red: 0.925, green: 0.914, blue: 0.888)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 56 * scale, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: max(0.75, 1.5 * scale))
                )

            VStack(spacing: 34 * scale) {
                Capsule()
                    .fill(Color(red: 0.10, green: 0.105, blue: 0.12))
                    .frame(width: 176 * scale, height: 64 * scale)
                    .overlay(
                        HStack(spacing: 24 * scale) {
                            Circle().fill(BrandPalette.signalRed).frame(width: 22 * scale, height: 22 * scale)
                            Circle().fill(BrandPalette.telemetryCyan).frame(width: 22 * scale, height: 22 * scale)
                            Circle().fill(BrandPalette.emeraldGreen).frame(width: 22 * scale, height: 22 * scale)
                        }
                    )

                HStack(spacing: 26 * scale) {
                    VStack(spacing: 12 * scale) {
                        HStack(spacing: 12 * scale) {
                            Circle().fill(Color.gray.opacity(0.65)).frame(width: 10 * scale, height: 10 * scale)
                            Circle().fill(Color.gray.opacity(0.65)).frame(width: 10 * scale, height: 10 * scale)
                            Circle().fill(Color.gray.opacity(0.65)).frame(width: 10 * scale, height: 10 * scale)
                        }
                        HStack(spacing: 12 * scale) {
                            Circle().fill(Color.gray.opacity(0.65)).frame(width: 10 * scale, height: 10 * scale)
                            Circle().fill(Color.gray.opacity(0.65)).frame(width: 10 * scale, height: 10 * scale)
                            Circle().fill(Color.gray.opacity(0.65)).frame(width: 10 * scale, height: 10 * scale)
                        }
                    }

                    Circle()
                        .fill(BrandPalette.braunOrange)
                        .frame(width: 58 * scale, height: 58 * scale)
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.16), radius: max(1, size * 0.08), y: max(0.5, size * 0.04))
    }
}

/// Short 3-letter hardware code for compact OLED tags.
extension AgentSource {
    var oledCode: String {
        switch self {
        case .antigravity: return "AGY"
        case .codex: return "CDX"
        case .deepseekHarness: return "DSH"
        case .claudeCode: return "CLD"
        case .kimiCode: return "KIM"
        case .workbuddy: return "WBD"
        case .custom: return "CLI"
        }
    }
}
