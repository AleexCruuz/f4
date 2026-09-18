# NOTICE

## This is a modified fork

**AltF4** is a modified version of **Vorssaint** (`vorssaint-utils`), originally
developed by the Vorssaint project maintainer.

- Upstream project: https://github.com/vorssaint/vorssaint-utils
- Forked from upstream `main` on **2026-09-18**
- This fork is **not affiliated with, endorsed by, or supported by** the
  Vorssaint project or its maintainer.

Report bugs in AltF4 to this fork. Do **not** report them to the upstream
Vorssaint project — they are not responsible for these modifications.

## License

AltF4 is licensed under **GPL-3.0-or-later**, the same license as upstream.
See [LICENSE](LICENSE) for the full text.

The original copyright notices in the source files are retained. Modified
files carry an additional notice identifying the modification.

This program comes with **ABSOLUTELY NO WARRANTY**. This is free software, and
you are welcome to redistribute it under the conditions of the GPL.

### Source availability

GPL-3.0 §6 requires that recipients of a binary can obtain the corresponding
source. The complete source for any AltF4 build is available at the repository
this NOTICE ships with. If you received a binary without the source, request it
from whoever distributed the binary.

## Trademarks

The upstream [TRADEMARKS.md](TRADEMARKS.md) states that the GPL grants rights to
the source code only, and does **not** grant permission to use the Vorssaint
name, logo, icon, bundle identity, trade dress, or signing identity.

Accordingly, this fork uses its own name, app icon, bundle identifier, signing
identity, and update feed. Nothing in this fork should be read as implying
endorsement or official status.

"Vorssaint" is referenced here solely to give accurate attribution of origin, as
required by the GPL.

## Changes from upstream

Per GPL-3.0 §5(a), modifications are recorded here with the date each landed.

### 2026-09-18 — Renamed the application to AltF4

- Renamed the app, executable, Swift package and target from `Vorssaint` to
  `AltF4`; moved `Sources/Vorssaint/` to `Sources/AltF4/`.
- Changed every bundle identifier from `com.vorssaint.*` to `com.altf4.*`,
  including the app, the developer variant and the fan-control helper. Because
  the app derives its Application Support directory from its bundle identifier,
  this also isolates the fork's data from an installed upstream build.
- Renamed `Resources/Vorssaint.entitlements` and the fan-control launch plist to
  match.
- **Original copyright notices were left untouched.** The 616 existing
  `Copyright (C) 2026 Vorssaint` headers remain exactly as upstream wrote them;
  the rename deliberately skipped every line carrying one. `AppInfo.copyright`
  now credits both projects.

### 2026-09-18 — Removed upstream brand assets

Upstream's artwork carries an explicit rights statement placing it **outside**
the GPL ("reserved brand material … not licensed under the GPL"), so this fork
has no licence to it and it has been deleted rather than reused or renamed:

- `Resources/Brand/AppIcon.icon/Assets/vorssaint-brandmark.svg`
- `Resources/Brand/logo.png`, `Resources/Brand/AppIcon-Default.png`
- `docs/assets/readme/logo.svg`, `logo-dark.svg`, `logo-dark.png`, `icon.png`
- `ReleaseAssets/vorssaint-3.1.4-showcase-1.mp4` (upstream promotional video)

Replaced with an original AltF4 brandmark (`altf4-brandmark.svg`, plus PNG
renditions), drawn for this fork and licensed under GPL-3.0-or-later like the
rest of the repository.

Remaining screenshots under `docs/assets/readme/` still show the upstream UI and
are stale; they need retaking before any release.

### 2026-09-18 — Added Clipboard AI

New feature not present upstream. Right-clicking a saved text entry in the
clipboard panel offers translate, summarise, clean up and explain, answered by a
model running on the user's own machine via Ollama. Off by default; the endpoint
is rejected unless it is on loopback, so clipboard contents never leave the Mac.

- New: `Sources/AltF4/Services/ClipboardAI/ClipboardAIService.swift`
- Modified: `Core/Defaults.swift`, `UI/MenuPanel/ClipboardQuickPanelView.swift`,
  `UI/Settings/ClipboardSettings.swift`

### 2026-09-18 — Redirected project links away from upstream

`AppInfo` previously carried upstream's website, donation page, Discord invite
and social account. A fork must not route its users to the upstream project's
support channels, and must not solicit donations through an account it does not
own. All of these now point at this fork's own repository, with a test pinning
that so an upstream URL cannot reappear silently.
