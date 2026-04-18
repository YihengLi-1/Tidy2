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
