import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// IBM Plex type ramp — Sans for chrome, Mono for symbols / stacks.
enum ProbeFont {
    private static let sansFamily = "IBM Plex Sans"
    private static let monoFamily = "IBM Plex Mono"

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        custom(family: sansFamily, postScript: sansPostScript(weight), size: size, weight: weight)
    }

    static func uiDigits(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        ui(size, weight: weight).monospacedDigit()
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        custom(family: monoFamily, postScript: monoPostScript(weight), size: size, weight: weight)
    }

    static func monoDigits(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        mono(size, weight: weight).monospacedDigit()
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        uiDigits(size, weight: weight)
    }

    private static func custom(family: String, postScript: String, size: CGFloat, weight: Font.Weight) -> Font {
        if NSFont(name: postScript, size: size) != nil {
            return Font.custom(postScript, size: size)
        }
        if NSFont(name: family, size: size) != nil {
            return Font.custom(family, size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight)
    }

    private static func sansPostScript(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "IBMPlexSans-Bold"
        case .semibold: return "IBMPlexSans-SmBld"
        case .medium: return "IBMPlexSans-Medm"
        default: return "IBMPlexSans"
        }
    }

    private static func monoPostScript(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "IBMPlexMono-Bold"
        case .semibold: return "IBMPlexMono-SmBld"
        case .medium: return "IBMPlexMono-Medm"
        default: return "IBMPlexMono"
        }
    }
}

/// Quiet paper / carbon surfaces. Syntax chroma only on semantic tokens.
enum ProbeTheme {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }

    static let canvas = dynamic(
        light: (0.976, 0.976, 0.972, 1.0),
        dark:  (0.090, 0.090, 0.094, 1.0)
    )
    static let surface = dynamic(
        light: (1.000, 1.000, 1.000, 1.0),
        dark:  (0.118, 0.118, 0.122, 1.0)
    )
    static let surfaceSubtle = dynamic(
        light: (0.945, 0.945, 0.940, 1.0),
        dark:  (0.145, 0.145, 0.150, 1.0)
    )
    static let surfaceRaised = dynamic(
        light: (0.910, 0.910, 0.905, 1.0),
        dark:  (0.180, 0.180, 0.186, 1.0)
    )

    static let hairline = dynamic(
        light: (0.0, 0.0, 0.0, 0.10),
        dark:  (1.0, 1.0, 1.0, 0.10)
    )
    static let hairlineSoft = dynamic(
        light: (0.0, 0.0, 0.0, 0.06),
        dark:  (1.0, 1.0, 1.0, 0.06)
    )

    static let ink = dynamic(
        light: (0.090, 0.090, 0.090, 1.0),
        dark:  (0.929, 0.929, 0.929, 1.0)
    )
    static let inkSecondary = dynamic(
        light: (0.330, 0.330, 0.330, 1.0),
        dark:  (0.690, 0.690, 0.700, 1.0)
    )
    static let inkMuted = dynamic(
        light: (0.540, 0.540, 0.530, 1.0),
        dark:  (0.500, 0.500, 0.510, 1.0)
    )

    static let brand = dynamic(
        light: (0.251, 0.471, 0.949, 1.0),
        dark:  (0.380, 0.686, 0.937, 1.0)
    )
    static let focus = brand
    static let focusSoft = brand

    static let ok = dynamic(
        light: (0.220, 0.580, 0.290, 1.0),
        dark:  (0.490, 0.765, 0.475, 1.0)
    )
    static let okSoft = ok

    static let busy = dynamic(
        light: (0.710, 0.435, 0.055, 1.0),
        dark:  (0.855, 0.620, 0.365, 1.0)
    )
    static let busySoft = busy

    static let blocked = dynamic(
        light: (0.780, 0.235, 0.275, 1.0),
        dark:  (0.878, 0.424, 0.459, 1.0)
    )
    static let blockedSoft = blocked

    static func signal(for kind: HangKindCompat) -> (solid: Color, soft: Color, fill: Color, border: Color) {
        switch kind {
        case .responsive:
            return (ok, okSoft, ok.opacity(0.12), ok.opacity(0.22))
        case .busy:
            return (busy, busySoft, busy.opacity(0.12), busy.opacity(0.24))
        case .blocked:
            return (blocked, blockedSoft, blocked.opacity(0.12), blocked.opacity(0.24))
        }
    }
}

enum HangKindCompat {
    case responsive
    case busy
    case blocked
}

/// Crisp vector brand mark matching `assets/hangprobe-icon.svg`.
struct BrandMarkView: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.15, green: 0.18, blue: 0.29),
                            Color(red: 0.08, green: 0.10, blue: 0.17),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
                )

            Canvas { ctx, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let midY = h * 0.54
                var wave = Path()
                wave.move(to: CGPoint(x: w * 0.16, y: midY))
                wave.addLine(to: CGPoint(x: w * 0.28, y: midY))
                wave.addLine(to: CGPoint(x: w * 0.38, y: h * 0.36))
                wave.addLine(to: CGPoint(x: w * 0.47, y: h * 0.70))
                wave.addLine(to: CGPoint(x: w * 0.56, y: h * 0.28))
                wave.addLine(to: CGPoint(x: w * 0.65, y: midY))

                ctx.stroke(
                    wave,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.29, green: 0.87, blue: 0.50),
                            Color(red: 0.38, green: 0.65, blue: 0.98),
                        ]),
                        startPoint: CGPoint(x: w * 0.16, y: midY),
                        endPoint: CGPoint(x: w * 0.65, y: midY)
                    ),
                    style: StrokeStyle(lineWidth: max(1.6, size * 0.09), lineCap: .round, lineJoin: .round)
                )

                var stall = Path()
                stall.move(to: CGPoint(x: w * 0.65, y: midY))
                stall.addLine(to: CGPoint(x: w * 0.84, y: midY))
                ctx.stroke(
                    stall,
                    with: .color(Color(red: 0.98, green: 0.44, blue: 0.52)),
                    style: StrokeStyle(lineWidth: max(1.5, size * 0.08), lineCap: .round)
                )

                let r = max(2.2, size * 0.105)
                let dotRect = CGRect(x: w * 0.65 - r, y: midY - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: dotRect), with: .color(Color(red: 0.98, green: 0.44, blue: 0.52)))
            }
        }
        .frame(width: size, height: size)
    }
}
