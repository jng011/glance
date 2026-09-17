//
//  GlanceTheme.swift
//  glance
//
//  Color and type tokens, kept here so OnboardingStepViews/OnboardingControls don't
//  repeat the same hex literals everywhere.
//

import SwiftUI

/// Irys palette.
///
/// The accent was `#3499FF` — system blue in a slightly lighter hat, and the
/// single most recognisable thing carried over from the app this forked from.
/// Renaming everything while keeping that blue is why the result still read as
/// the old app with new labels.
///
/// It is now `#30D158` — Apple's dark-mode system green, which is the colour of a
/// Face ID scan ring. An earlier pass used a muted `#4E9142` and read as dark.
/// so the chrome and the thing you actually watch during an unlock agree with
/// each other. Green also earns its place here: it is the colour a biometric
/// scan reads as, and it is not the colour of every other Mac utility.
///
/// The type name is unchanged deliberately — it appears in roughly a hundred
/// call sites, it is invisible to users, and renaming it is the change most
/// likely to break the build for no gain.
enum GlanceTheme {
    private static let accentRGB = (r: 0x30 / 255.0, g: 0xD1 / 255.0, b: 0x58 / 255.0)
    static let accent = Color(red: accentRGB.r, green: accentRGB.g, blue: accentRGB.b)

    /// White at 0, `accent` at 1.
    static func whiteToAccent(_ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        return Color(
            red: 1 + (accentRGB.r - 1) * t,
            green: 1 + (accentRGB.g - 1) * t,
            blue: 1 + (accentRGB.b - 1) * t
        )
    }
    /// Accent-derived shades for the enrollment sweep, shifted so layered streaks read
    /// as one body of light rather than several flat shapes.
    static let accentPale   = Color(red: 0xD6 / 255, green: 0xEB / 255, blue: 0xC9 / 255)
    static let accentBright = Color(red: 0x5E / 255, green: 0xE0 / 255, blue: 0x80 / 255)
    static let accentDeep   = Color(red: 0x1B / 255, green: 0x7A / 255, blue: 0x33 / 255)
    static let surface = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
    static let surfaceRaised = Color(red: 0x32 / 255, green: 0x32 / 255, blue: 0x32 / 255)
    static let panel = Color.black
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0x94 / 255, green: 0x94 / 255, blue: 0x94 / 255)
    static let textDetail = Color(red: 0xBD / 255, green: 0xBD / 255, blue: 0xBD / 255)
    static let placeholder = Color(red: 0x2F / 255, green: 0x2F / 255, blue: 0x2F / 255)
    /// Deliberately brighter and more saturated than `accent`, which is now also
    /// green: a granted state has to read as a state change, not as chrome.
    static let statusGranted = Color(red: 0x64 / 255, green: 0xF5 / 255, blue: 0xA8 / 255)
    static let statusDenied = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

    enum Font {
        /// Scaled up so content reads clearly at the wider `OnboardingMetrics.panelWidth`.
        static let title = SwiftUI.Font.system(size: 26, weight: .bold)
        static let button = SwiftUI.Font.system(size: 13, weight: .medium)
        static let rowTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        static let grantLabel = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let rowDetail = SwiftUI.Font.system(size: 11, weight: .regular)
        static let passwordCaption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let passwordPlaceholder = SwiftUI.Font.system(size: 12, weight: .regular)
        static let instruction = SwiftUI.Font.system(size: 15, weight: .medium)
    }
}
