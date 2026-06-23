import SwiftUI
import AppKit

/// App appearance choice, persisted and applied via `.preferredColorScheme`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Adaptive palette (FlowAI-inspired)

extension Color {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Soft window background.
    static let appBackground = dynamic(
        light: NSColor(calibratedWhite: 0.96, alpha: 1),
        dark: NSColor(calibratedWhite: 0.11, alpha: 1)
    )

    /// Card / panel surface.
    static let appCard = dynamic(
        light: .white,
        dark: NSColor(calibratedWhite: 0.17, alpha: 1)
    )

    /// Sidebar surface.
    static let appSidebar = dynamic(
        light: NSColor(calibratedWhite: 0.975, alpha: 1),
        dark: NSColor(calibratedWhite: 0.14, alpha: 1)
    )

    /// Hairline borders.
    static let appBorder = dynamic(
        light: NSColor(calibratedWhite: 0.90, alpha: 1),
        dark: NSColor(calibratedWhite: 0.26, alpha: 1)
    )
}
