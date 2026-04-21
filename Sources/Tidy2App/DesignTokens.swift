import SwiftUI

// MARK: - Tidy Design System
// Single source of truth for spacing, radii, and opacities.
// Use these constants instead of hardcoded numbers throughout the app.

enum TidySpacing {
    /// 4pt — tight internal gap between icon and text, badge padding
    static let xxs: CGFloat = 4
    /// 6pt — caption/chip internal padding
    static let xs: CGFloat = 6
    /// 8pt — row internal spacing, small gaps
    static let sm: CGFloat = 8
    /// 10pt — list row internal padding, button spacing
    static let md: CGFloat = 10
    /// 12pt — card section spacing, inter-element gap
    static let lg: CGFloat = 12
    /// 16pt — card inner padding (compact cards), list row vertical padding
    static let xl: CGFloat = 16
    /// 20pt — standard card inner padding, section outer padding
    static let xxl: CGFloat = 20
    /// 24pt — screen outer padding, large view padding
    static let xxxl: CGFloat = 24
}

enum TidyRadius {
    /// 6pt — small chip / tag
    static let chip: CGFloat = 6
    /// 8pt — small button, compact row
    static let sm: CGFloat = 8
    /// 10pt — file row card
    static let md: CGFloat = 10
    /// 12pt — standard card (summary, section background)
    static let lg: CGFloat = 12
    /// 14pt — action card (digest page cards)
    static let xl: CGFloat = 14
    /// 16pt — hero card / clean state card
    static let xxl: CGFloat = 16
}

enum TidyOpacity {
    /// 0.06 — very subtle background tint (clean card)
    static let ultraLight: Double = 0.06
    /// 0.08 — standard card background
    static let light: Double = 0.08
    /// 0.10 — slightly more visible card (colored action cards)
    static let medium: Double = 0.10
    /// 0.12 — hover / selected / badge background
    static let strong: Double = 0.12
    /// 0.14 — focused row highlight
    static let focused: Double = 0.14
    /// 0.18 — sidebar selection highlight
    static let selection: Double = 0.18
}

// MARK: - View Modifiers

extension View {
    /// Standard card style: gray background, rounded corners
    func tidyCard(radius: CGFloat = TidyRadius.lg, opacity: Double = TidyOpacity.light) -> some View {
        self
            .background(Color.gray.opacity(opacity))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .tidyShadow(radius: 6, y: 1)
    }

    /// Colored tinted card style
    func tidyColorCard(_ color: Color, radius: CGFloat = TidyRadius.xl, opacity: Double = TidyOpacity.medium) -> some View {
        self
            .background(color.opacity(opacity))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    /// Standard screen-level padding
    func tidyScreenPadding() -> some View {
        self.padding(TidySpacing.xxl)
    }
}

// MARK: - Semantic Colors

enum TidyColor {
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue
    static let ai = Color.purple

    static let successBg  = Color.green.opacity(TidyOpacity.medium)
    static let warningBg  = Color.orange.opacity(TidyOpacity.medium)
    static let errorBg    = Color.red.opacity(TidyOpacity.medium)
    static let infoBg     = Color.blue.opacity(TidyOpacity.medium)
    static let aiBg       = Color.purple.opacity(TidyOpacity.medium)
}

// MARK: - Animation

enum TidyAnimation {
    static let standard  = Animation.easeInOut(duration: 0.22)
    static let fast      = Animation.easeInOut(duration: 0.14)
    static let spring    = Animation.spring(response: 0.35, dampingFraction: 0.75)
    static let springFast = Animation.spring(response: 0.22, dampingFraction: 0.8)
}

// MARK: - Shadow

struct TidyShadow: ViewModifier {
    var color: Color = .black.opacity(0.06)
    var radius: CGFloat = 8
    var y: CGFloat = 2
    func body(content: Content) -> some View {
        content.shadow(color: color, radius: radius, x: 0, y: y)
    }
}

extension View {
    func tidyShadow(radius: CGFloat = 8, y: CGFloat = 2) -> some View {
        modifier(TidyShadow(radius: radius, y: y))
    }

    func tidyShadowStrong() -> some View {
        modifier(TidyShadow(color: .black.opacity(0.10), radius: 16, y: 4))
    }
}
