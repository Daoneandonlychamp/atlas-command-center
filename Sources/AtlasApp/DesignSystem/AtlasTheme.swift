import SwiftUI

// MARK: - ATLAS Design System

public enum AtlasTheme {

    // MARK: - Colors: 5-Tier Surface Elevation

    public enum Colors {
        // Neutral, adaptive surface hierarchy. The old warm gold/navy cast made
        // every control look illuminated; these read as physical materials.
        public static let background     = Color.atlasAdaptive(light: 0xF0ECE4, dark: 0x090A0C)
        public static let surfaceDark    = Color.atlasAdaptive(light: 0xE7E2D8, dark: 0x101216)
        public static let cardSurface    = Color.atlasAdaptive(light: 0xF7F3EC, dark: 0x15171C)
        /// Faint fills for meter tracks and small chips. These used to be a white
        /// wash, which is invisible on a light ground — the tint has to flip with
        /// the appearance, not just the things drawn on top of it.
        public static let trackWash      = Color.atlasAdaptive(light: 0xDDD7CC, dark: 0x24262B)
        public static let chipWash       = Color.atlasAdaptive(light: 0xE6E0D5, dark: 0x1D2025)
        public static let cardElevated   = Color.atlasAdaptive(light: 0xFCF9F3, dark: 0x1B1E24)
        public static let cardFloat      = Color.atlasAdaptive(light: 0xFFFDF8, dark: 0x22252C)

        // Borders
        public static let borderLuminous = Color.atlasAdaptive(light: 0xB8B0A3, dark: 0x383C43)
        public static let borderSubtle   = Color.atlasAdaptive(light: 0xD2CABE, dark: 0x292D33)

        // Compatibility names retained so existing screens inherit the new
        // monochrome accent without a risky repository-wide rename.
        public static let champagneGold  = Color.atlasAdaptive(light: 0x1D1B18, dark: 0xF0F0EE)
        public static let champagneLight = Color.atlasAdaptive(light: 0x4F4A43, dark: 0xC2C4C7)
        public static let champagneGlow  = Color.primary.opacity(0.16)
        public static let champagneMuted = borderSubtle

        // Text hierarchy
        public static let textPrimary    = Color.atlasAdaptive(light: 0x1D1B18, dark: 0xF0F0EE)
        public static let textSecondary  = Color.atlasAdaptive(light: 0x4F4A43, dark: 0xB1B3B7)
        public static let textMuted      = Color.atlasAdaptive(light: 0x696258, dark: 0x8E9197)
        public static let textSubtle     = Color.atlasAdaptive(light: 0x7E766A, dark: 0x6F737A)

        // Status
        public static let success = Color(red: 0.20, green: 0.78, blue: 0.35)
        public static let warning = Color(red: 1.00, green: 0.62, blue: 0.04)
        public static let error   = Color(red: 1.00, green: 0.23, blue: 0.19)
        public static let info    = Color(red: 0.04, green: 0.52, blue: 1.00)
    }

    // MARK: - Gradients

    public enum Gradients {
        public static let background = LinearGradient(
            colors: [Colors.background, Colors.surfaceDark.opacity(0.78), Colors.background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let champagneAccent = LinearGradient(
            colors: [Colors.textPrimary, Colors.textPrimary.opacity(0.68)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Gradient border that simulates directional edge lighting
        public static let cardBorder = LinearGradient(
            colors: [Colors.borderLuminous, Colors.borderSubtle.opacity(0.62)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let goldBorder = LinearGradient(
            colors: [Colors.borderLuminous, Colors.borderSubtle],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // MARK: Control surfaces
        //
        // Light falls from above, so a control sits a shade brighter along its
        // top edge and settles into the panel at the bottom. Built from the
        // adaptive tokens rather than fixed colours, so the same definition
        // reads correctly in both appearances. Vertical, not diagonal: these
        // are small surfaces, and a diagonal sweep on a 30pt control reads as a
        // smudge rather than as lighting.

        /// The default control: Finder, Terminal, command chips.
        public static let buttonSecondary = LinearGradient(
            colors: [Colors.cardFloat, Colors.cardElevated],
            startPoint: .top,
            endPoint: .bottom
        )

        public static let buttonSecondaryHover = LinearGradient(
            colors: [Colors.cardFloat, Colors.cardFloat.opacity(0.82)],
            startPoint: .top,
            endPoint: .bottom
        )

        /// The one action a view most wants you to take.
        public static let buttonPrimary = LinearGradient(
            colors: [Colors.textPrimary, Colors.textPrimary.opacity(0.86)],
            startPoint: .top,
            endPoint: .bottom
        )

        public static let buttonPrimaryHover = LinearGradient(
            colors: [Colors.textPrimary, Colors.textPrimary.opacity(0.96)],
            startPoint: .top,
            endPoint: .bottom
        )

        /// A quieter surface for controls that sit inside a card already.
        public static let buttonSurface = LinearGradient(
            colors: [Colors.cardElevated, Colors.cardSurface],
            startPoint: .top,
            endPoint: .bottom
        )

        /// The specular line along a control's top edge. Applied as a thin
        /// stroke rather than a fill, which is what separates a lit edge from a
        /// washed-out button.
        public static let edgeHighlight = LinearGradient(
            colors: [Color.white.opacity(0.12), Color.white.opacity(0.02), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Typography Scale

    public enum Typography {
        public static let largeTitle  = Font.system(size: 28, weight: .bold)
        public static let title       = Font.system(size: 22, weight: .bold)
        public static let headline    = Font.system(size: 17, weight: .semibold)
        public static let body        = Font.system(size: 14, weight: .regular)
        public static let callout     = Font.system(size: 13, weight: .medium)
        public static let caption     = Font.system(size: 12, weight: .medium)
        public static let footnote    = Font.system(size: 11, weight: .medium)
        public static let label       = Font.system(size: 10, weight: .bold)
        public static let mono        = Font.system(size: 13, weight: .regular, design: .monospaced)
        public static let monoSmall   = Font.system(size: 11, weight: .medium, design: .monospaced)
        public static let numeric     = Font.system(size: 26, weight: .bold, design: .rounded)
        public static let numericSmall = Font.system(size: 18, weight: .semibold, design: .rounded)
    }

    // MARK: - Spacing

    public enum Spacing {
        public static let xs: CGFloat   = 4
        public static let sm: CGFloat   = 8
        public static let md: CGFloat   = 12
        public static let lg: CGFloat   = 16
        public static let xl: CGFloat   = 24
        public static let xxl: CGFloat  = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Corner Radius

    public enum CornerRadius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
    }
}

/// Shared app canvas with a single, neutral light source. It supplies depth
/// without tinting the interface gold or making every panel glow independently.
public struct AtlasBackdrop: View {
    public init() {}

    public var body: some View {
        ZStack {
            AtlasTheme.Gradients.background
            RadialGradient(
                colors: [Color.white.opacity(0.085), Color.clear],
                center: UnitPoint(x: 0.18, y: -0.08),
                startRadius: 0,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color.white.opacity(0.035), Color.clear],
                center: UnitPoint(x: 0.92, y: 0.08),
                startRadius: 0,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Color Hex Extension

extension NSColor {
    /// An `NSColor` that resolves per appearance.
    ///
    /// AppKit views that are configured rather than described — an `NSTextView`
    /// handed a `textColor`, say — need the colour itself to be dynamic, because
    /// nothing re-runs to hand them a new one when the appearance flips.
    static func atlasAdaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        func solid(_ value: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha
            )
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? solid(dark)
                : solid(light)
        }
    }
}

extension Color {
    fileprivate static func atlasAdaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor.atlasAdaptive(light: light, dark: dark))
    }

    public init(hex: String) {
        let hexStr = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexStr).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexStr.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

// MARK: - Premium Components

/// A card with gradient edge-lit border, hover lift, and configurable depth.
public struct GlassCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let showBorder: Bool
    private let hoverEffect: Bool
    private let surface: Color

    @State private var isHovered = false

    public init(
        padding: CGFloat = AtlasTheme.Spacing.lg,
        cornerRadius: CGFloat = AtlasTheme.CornerRadius.lg,
        showBorder: Bool = true,
        hoverEffect: Bool = true,
        surface: Color = AtlasTheme.Colors.cardSurface,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.showBorder = showBorder
        self.hoverEffect = hoverEffect
        self.surface = surface
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        showBorder ? AtlasTheme.Gradients.cardBorder : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(isHovered && hoverEffect ? 0.18 : 0.10),
                    radius: isHovered && hoverEffect ? 18 : 10,
                    y: isHovered && hoverEffect ? 8 : 4)
            .offset(y: isHovered && hoverEffect ? -1 : 0)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// LED-like status dot with soft radial glow.
public struct GlowDot: View {
    public let color: Color
    public var size: CGFloat = 8
    public var glowRadius: CGFloat = 6

    public init(color: Color, size: CGFloat = 8, glowRadius: CGFloat = 6) {
        self.color = color
        self.size = size
        self.glowRadius = glowRadius
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size + glowRadius, height: size + glowRadius)
                .blur(radius: glowRadius * 0.6)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size + glowRadius + 2, height: size + glowRadius + 2)
    }
}

/// Thin champagne gold leading accent bar for cards and nav items.
public struct AccentBar: View {
    public var color: Color = AtlasTheme.Colors.champagneGold
    public var width: CGFloat = 3
    public var height: CGFloat? = nil

    public init(color: Color = AtlasTheme.Colors.champagneGold, width: CGFloat = 3, height: CGFloat? = nil) {
        self.color = color
        self.width = width
        self.height = height
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: width / 2)
            .fill(color)
            .frame(width: width, height: height)
    }
}

/// Consistent section title with optional trailing action.
public struct SectionHeader: View {
    public let title: String
    public var actionTitle: String? = nil
    public var action: (() -> Void)? = nil

    public init(title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(AtlasTheme.Typography.label)
                .foregroundColor(AtlasTheme.Colors.textMuted)
                .tracking(1.5)
            Spacer()
            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(actionTitle)
                            .font(AtlasTheme.Typography.caption)
                            .foregroundColor(AtlasTheme.Colors.champagneGold)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(AtlasTheme.Colors.champagneGold)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Button with smooth hover scale and opacity micro-interaction.
public struct PremiumButton: View {
    public let label: String
    public let icon: String?
    public let style: Style
    public let action: () -> Void

    @State private var isHovered = false

    public enum Style {
        case primary, secondary, destructive, ghost
    }

    public init(_ label: String, icon: String? = nil, style: Style = .secondary, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(label)
                    .font(AtlasTheme.Typography.caption)
                    // Without these the label wraps mid-word when the row runs
                    // out of space — "Terminal" became "Ter / min / al". A
                    // button should keep its width and let the row scroll or
                    // wrap instead.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(backgroundStyle)
            .foregroundColor(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            // The lit edge sits above the border so the top of the control
            // catches the light. Skipped on .ghost, which has no surface to
            // light, and on .primary, which is already near-white.
            .overlay(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                    .strokeBorder(AtlasTheme.Gradients.edgeHighlight, lineWidth: 1)
                    .opacity(hasLitEdge ? 1 : 0)
            )
            // The gradient already brightens on hover, so this is a nudge now
            // rather than the whole hover state.
            .brightness(isHovered ? 0.02 : 0)
            .offset(y: isHovered ? -0.5 : 0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var hasLitEdge: Bool {
        switch style {
        case .secondary, .destructive: return true
        case .primary, .ghost:         return false
        }
    }

    private var backgroundStyle: LinearGradient {
        switch style {
        case .primary:
            return isHovered ? AtlasTheme.Gradients.buttonPrimaryHover
                             : AtlasTheme.Gradients.buttonPrimary
        case .secondary:
            return isHovered ? AtlasTheme.Gradients.buttonSecondaryHover
                             : AtlasTheme.Gradients.buttonSecondary
        case .destructive:
            return LinearGradient(
                colors: [AtlasTheme.Colors.error.opacity(isHovered ? 0.28 : 0.18),
                         AtlasTheme.Colors.error.opacity(isHovered ? 0.18 : 0.10)],
                startPoint: .top, endPoint: .bottom)
        case .ghost:
            return LinearGradient(
                colors: isHovered
                    ? [AtlasTheme.Colors.cardElevated, AtlasTheme.Colors.cardSurface]
                    : [.clear, .clear],
                startPoint: .top, endPoint: .bottom)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:     return AtlasTheme.Colors.background
        case .secondary:   return AtlasTheme.Colors.textPrimary
        case .destructive: return AtlasTheme.Colors.error
        case .ghost:       return AtlasTheme.Colors.textSecondary
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:     return AtlasTheme.Colors.textPrimary.opacity(0.22)
        case .secondary:   return AtlasTheme.Colors.borderLuminous
        case .destructive: return AtlasTheme.Colors.error.opacity(0.3)
        case .ghost:       return .clear
        }
    }
}

// MARK: - Legacy Upgraded Components

public struct MetricCard: View {
    public let title: String
    public let value: String
    public let icon: String
    public let color: Color

    @State private var isHovered = false

    public init(title: String, value: String, icon: String, color: Color) {
        self.title = title
        self.value = value
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
                Spacer()
            }
            Text(value)
                .font(AtlasTheme.Typography.numeric)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
            Text(title)
                .font(AtlasTheme.Typography.footnote)
                .foregroundColor(AtlasTheme.Colors.textSecondary)
        }
        .padding(AtlasTheme.Spacing.lg)
        .background(AtlasTheme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous)
                .stroke(AtlasTheme.Gradients.cardBorder, lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(isHovered ? 0.4 : 0.2),
            radius: isHovered ? 12 : 6,
            y: isHovered ? 4 : 2
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Premium stat tile: large number left, subtitle + delta below, tinted icon badge on the RIGHT.
/// Tappable — whole card acts as a button with hover lift.
public struct StatCard: View {
    public let title: String
    public let value: String
    public let icon: String
    public let accent: Color
    public var caption: String? = nil
    public var action: (() -> Void)? = nil

    @State private var isHovered = false

    public init(title: String, value: String, icon: String, accent: Color, caption: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.icon = icon
        self.accent = accent
        self.caption = caption
        self.action = action
    }

    public var body: some View {
        Button(action: { action?() }) {
            HStack(alignment: .top, spacing: AtlasTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xs) {
                    Text(value)
                        .font(AtlasTheme.Typography.numeric)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                        .contentTransition(.numericText())
                    Text(title.uppercased())
                        .font(AtlasTheme.Typography.label)
                        .tracking(1.0)
                        .foregroundColor(AtlasTheme.Colors.textMuted)
                    if let caption {
                        Text(caption)
                            .font(AtlasTheme.Typography.footnote)
                            .foregroundColor(accent)
                    }
                }
                Spacer(minLength: 0)
                // Icon badge — right aligned
                ZStack {
                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                        .fill(accent.opacity(isHovered ? 0.22 : 0.14))
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(accent)
                }
                .frame(width: 38, height: 38)
            }
            .padding(AtlasTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AtlasTheme.Colors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous)
                    .stroke(isHovered ? accent.opacity(0.35) : AtlasTheme.Colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 14 : 6, y: isHovered ? 5 : 2)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .offset(y: isHovered ? -1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

public struct DetailCard: View {
    public let label: String
    public let value: String
    public let icon: String

    public init(label: String, value: String, icon: String) {
        self.label = label
        self.value = value
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: AtlasTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(AtlasTheme.Colors.champagneGold)

            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(AtlasTheme.Typography.label)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                    .tracking(0.8)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
            }
            Spacer()
        }
        .padding(AtlasTheme.Spacing.md)
        .background(AtlasTheme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                .stroke(AtlasTheme.Gradients.cardBorder, lineWidth: 1)
        )
    }
}
