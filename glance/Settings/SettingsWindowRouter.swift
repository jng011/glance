//
//  SettingsWindowRouter.swift
//  Irys
//
//  Lets code outside the Settings window ask it to open on a particular tab.
//
//  `SettingsWindowView` keeps its tab in `@State private var selection`, which
//  nothing else can reach. Rather than hoisting that state — which would make
//  every tab change a global event — this carries a one-shot *request* that the
//  view consumes and clears.
//

import Observation

@Observable
@MainActor
final class SettingsWindowRouter {
    static let shared = SettingsWindowRouter()

    /// Set by a caller before revealing the window; cleared by the view once
    /// applied. One-shot on purpose: a sticky value would drag the window back to
    /// the same tab every time it reopened.
    var requestedTab: SettingsTab?

    private init() {}
}
