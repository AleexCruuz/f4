// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Static identity of the app, shared by UI, notifications and tooling.
enum AppInfo {
    static let name = "F4"
    /// F4 is a modified fork of Vorssaint, so both authors are credited.
    static let copyright = "© 2026 Vorssaint · © 2026 F4 contributors"

    /// TODO: point this at the published fork before distributing any binary.
    /// GPL-3.0 §6 requires anyone who receives a build to be able to get the
    /// corresponding source.
    static let repositoryURL = URL(string: "https://github.com/AleexCruuz/f4")!

    /// The fork has no site, donation page, chat server or social account of its
    /// own. The upstream ones are deliberately NOT reused: they belong to the
    /// Vorssaint project, and sending this fork's users there would route them to
    /// a community that did not ship this build and cannot support it. Until the
    /// fork has its own, every entry point lands on the repository.
    static let websiteURL = repositoryURL
    static let coffeeURL = repositoryURL
    static let discordURL = repositoryURL
    static let socialURL = repositoryURL

    /// The bundle version. The fallback only applies to the bare binary
    /// (e.g. `--selftest`), never the shipped app, which reads its Info.plist.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// True for the local "F4 (Developer)" build (bundle id ends in `.dev`).
    /// It is never published and never auto-updates; all work is tested here first.
    static var isDeveloperBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }

    /// True when the current version is a pre-release (e.g. 3.3.4-beta.1 or 3.3.4-rc.1).
    static var isBeta: Bool {
        if isDeveloperBuild && UserDefaults.standard.bool(forKey: DefaultsKey.simulateBetaUI) {
            return true
        }
        let v = version.lowercased()
        return v.contains("-beta") || v.contains("-rc") || v.contains("-alpha")
    }

    /// The git commit a Developer build was compiled from, e.g. "ed2ebba · 2026-06-15 21:30"
    /// (or with a "-dirty" suffix on the SHA for uncommitted changes). build.sh stamps
    /// this into the Developer bundle only, so you can confirm at a glance that the
    /// running dev app matches the source you are about to change. nil in the official app.
    static var buildCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "F4BuildCommit") as? String
    }
}
