import SwiftUI
#if os(macOS)
import AppKit
#endif

enum DocTheme {
    static let contentWidth: CGFloat = 720

    static let accent = dynamic(
        light: Color(red: 0.72, green: 0.44, blue: 0.15),
        dark: Color(red: 0.92, green: 0.67, blue: 0.35)
    )

    static let heroGradientColors: [Color] = [
        Color(red: 0.99, green: 0.80, blue: 0.44),
        Color(red: 0.90, green: 0.56, blue: 0.22),
        Color(red: 0.64, green: 0.35, blue: 0.14)
    ]

    static var heroGradient: LinearGradient {
        LinearGradient(colors: heroGradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let codeBackground = Color(red: 0.10, green: 0.105, blue: 0.125)
    static let codeForeground = Color(red: 0.93, green: 0.91, blue: 0.86)
    static let codeBadge = Color(red: 0.93, green: 0.75, blue: 0.45)

    static let inlineCode = dynamic(
        light: Color(red: 0.63, green: 0.36, blue: 0.10),
        dark: Color(red: 0.95, green: 0.73, blue: 0.43)
    )

    static let cardFill = Color.primary.opacity(0.035)
    static let cardStroke = Color.primary.opacity(0.09)
    static let quoteFill = accent.opacity(0.06)

    static var heroTitleFont: Font {
        platform(macos: Font.system(size: 46, weight: .heavy, design: .rounded),
                 ios: Font.system(size: 38, weight: .heavy, design: .rounded))
    }

    static var articleTitleFont: Font {
        platform(macos: Font.system(size: 29, weight: .bold, design: .rounded),
                 ios: Font.system(.largeTitle, design: .rounded).weight(.bold))
    }

    static func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return platform(macos: Font.system(size: 24, weight: .bold),
                            ios: Font.title.bold())
        case 2:
            return platform(macos: Font.system(size: 20, weight: .bold),
                            ios: Font.title2.bold())
        case 3:
            return platform(macos: Font.system(size: 16.5, weight: .semibold),
                            ios: Font.title3.weight(.semibold))
        default:
            return platform(macos: Font.system(size: 15, weight: .semibold),
                            ios: Font.headline)
        }
    }

    static var bodyFont: Font {
        platform(macos: Font.system(size: 15), ios: Font.body)
    }

    static var calloutFont: Font {
        platform(macos: Font.system(size: 13.5), ios: Font.callout)
    }

    static var summaryFont: Font {
        platform(macos: Font.system(size: 16), ios: Font.title3)
    }

    static var codeFont: Font {
        platform(macos: Font.system(size: 13, design: .monospaced),
                 ios: Font.system(size: 13.5, design: .monospaced))
    }

    static var bodySpacing: CGFloat { 7 }

    static func platform(macos: Font, ios: Font) -> Font {
        #if os(macOS)
        return macos
        #else
        return ios
        #endif
    }

    static func platform(macos: CGFloat, ios: CGFloat) -> CGFloat {
        #if os(macOS)
        return macos
        #else
        return ios
        #endif
    }

    static func dynamic(light: Color, dark: Color) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}
