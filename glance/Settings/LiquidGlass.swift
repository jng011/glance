//
//  LiquidGlass.swift
//  Irys
//
//  One place that knows about macOS 26's glass materials, so the availability
//  check exists once instead of at every call site.
//
//  WHAT IS ACTUALLY AVAILABLE, verified against the macOS 27.0 SDK's own
//  SwiftUI.swiftinterface rather than assumed:
//
//      GlassButtonStyle           @available(macOS 26.0, *)   .buttonStyle(.glass)
//      GlassProminentButtonStyle  @available(macOS 26.0, *)   .buttonStyle(.glassProminent)
//
//  That is the whole surface. There is **no** `glassEffect(_:in:)` modifier in
//  this SDK — grepping the interface for it returns nothing, and the only
//  Glass-named symbols are those two button styles. An earlier version of this
//  file assumed the iOS-style container API existed here and would not have
//  compiled. So arbitrary surfaces cannot be made glass on macOS; the existing
//  `.ultraThinMaterial` / `SettingsMetrics.rowColor` chrome stays as it is,
//  which is the correct look for a grouped settings card anyway.
//
//  The deployment target stays at macOS 15. Two separate builds were considered
//  and rejected: two targets means two code paths, two sets of bugs and double
//  the testing, forever, for a difference that changes nothing functional.
//
//  On the system "Liquid Glass" appearance control (Clear vs Tinted): it is a
//  system-wide rendering preference that the OS applies to these materials
//  itself. There is no app-facing API to read it and nothing for an app to do
//  about it — a button using `.glass` simply renders however the user has asked
//  for. The one related signal that does matter is the accessibility
//  reduce-transparency setting, and AppKit already honours that automatically.
//

import SwiftUI

extension View {
    /// The system glass button style on macOS 26+, falling back to whatever the
    /// caller was already using.
    ///
    /// Passing the fallback in rather than hardcoding it keeps the pre-26
    /// rendering byte-identical to before, which is the point: this should add a
    /// finish on new systems, not quietly restyle old ones.
    @ViewBuilder
    func irysGlassButton<F: PrimitiveButtonStyle>(fallback: F, prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(fallback)
        }
    }

    /// True when the glass materials are available.
    ///
    /// Prefer the modifier above. Branching layout on OS version is how a
    /// codebase ends up with two designs to maintain, which is the thing the
    /// single-binary decision was meant to avoid — this exists for the rare case
    /// where a measurement, not a style, has to differ.
    static var irysSupportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}
