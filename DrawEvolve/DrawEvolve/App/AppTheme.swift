import SwiftUI

/// Centralized theme for DrawEvolve
/// Uses system colors where possible for accessibility and dark mode support
enum AppTheme {
    // MARK: - Colors

    /// Primary brand color (used for main actions, accents)
    static let primaryColor = Color.blue

    /// Secondary color (used for less prominent elements)
    static let secondaryColor = Color.gray

    /// Background color (adapts to light/dark mode)
    static let backgroundColor = Color(uiColor: .systemBackground)

    /// Primary text color (adapts to light/dark mode)
    static let textColor = Color(uiColor: .label)

    /// Secondary text color for hints and descriptions (adapts to light/dark mode)
    static let secondaryTextColor = Color(uiColor: .secondaryLabel)

    /// Destructive action color (e.g., Clear button)
    static let destructiveColor = Color.red

    // MARK: - Typography

    /// Large titles (e.g., onboarding headers)
    static let titleFont = Font.system(size: 28, weight: .bold)

    /// Section headings
    static let headlineFont = Font.system(size: 20, weight: .semibold)

    /// Body text (default for most content)
    static let bodyFont = Font.system(size: 16, weight: .regular)

    /// Small text for hints and captions
    static let captionFont = Font.system(size: 14, weight: .light)

    // MARK: - Spacing

    /// Small padding (8pt)
    static let paddingSmall: CGFloat = 8

    /// Medium padding (16pt) - most common
    static let paddingMedium: CGFloat = 16

    /// Large padding (24pt) - section spacing
    static let paddingLarge: CGFloat = 24

    // MARK: - Dimensions

    /// Standard button height
    static let buttonHeight: CGFloat = 50

    /// Corner radius for rounded elements
    static let cornerRadius: CGFloat = 12
}
