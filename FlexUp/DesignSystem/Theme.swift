import SwiftUI
import UIKit

/// FLEX UP visual identity: graphite base, electric violet + turquoise accents, soft glows.
enum Theme {
    // Brand accents (same in both themes, tuned for contrast on graphite and on light grey).
    static let violet = Color(hex: 0x8A2BFF)
    static let violetSoft = Color(hex: 0xB07CFF)
    static let teal = Color(hex: 0x19E3D1)
    static let tealDeep = Color(hex: 0x0FB5A7)
    static let like = Color(hex: 0xFF3B6B)
    static let warning = Color(hex: 0xFFB020)

    // Adaptive surfaces.
    static let background = Color(light: 0xF4F4F8, dark: 0x0E0F13)
    static let surface = Color(light: 0xFFFFFF, dark: 0x17181F)
    static let elevated = Color(light: 0xECECF3, dark: 0x22242E)
    static let stroke = Color(light: 0xDCDCE6, dark: 0x2E3140)
    static let textPrimary = Color(light: 0x14151A, dark: 0xF5F5FA)
    static let textSecondary = Color(light: 0x5D6070, dark: 0xA3A6B8)
    /// Accent text that must stay readable on both backgrounds.
    static let accentText = Color(light: 0x6A1BE0, dark: 0xB07CFF)

    static let brandGradient = LinearGradient(colors: [violet, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandGradientH = LinearGradient(colors: [violet, teal], startPoint: .leading, endPoint: .trailing)
    static let scrim = LinearGradient(colors: [.black.opacity(0), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
    static let topScrim = LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0)], startPoint: .top, endPoint: .bottom)

    static let corner: CGFloat = 16
    static let cornerSmall: CGFloat = 10
    static let minTap: CGFloat = 44
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Parses "#RRGGBB" strings coming from profile avatar colours.
    init(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(hex: UInt32(s, radix: 16) ?? 0x8A2BFF)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Modifiers

struct GlowModifier: ViewModifier {
    var color: Color = Theme.violet
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content.shadow(color: color.opacity(0.55), radius: radius)
    }
}

extension View {
    func glow(_ color: Color = Theme.violet, radius: CGFloat = 12) -> some View { modifier(GlowModifier(color: color, radius: radius)) }

    func card() -> some View {
        padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.stroke, lineWidth: 0.5))
    }

    /// Readable white text over video.
    func overlayText() -> some View { foregroundColor(.white).shadow(color: .black.opacity(0.5), radius: 2, y: 1) }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var isEnabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.brandGradientH) : AnyShapeStyle(Color.gray.opacity(0.4)))
            )
            .glow(isEnabled ? Theme.violet : .clear, radius: configuration.isPressed ? 4 : 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
