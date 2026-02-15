# CLAUDE.md

## Project Overview

ClaudeCodeStats is a native macOS menu bar app (SwiftUI) that shows Claude Code usage limits, Claude service health status, and CLI version update notifications.

## Build

```bash
cd ClaudeCodeStats
xcodebuild -scheme ClaudeCodeStats -configuration Release build
```

The built `.app` is in `~/Library/Developer/Xcode/DerivedData/ClaudeCodeStats-*/Build/Products/Release/`.

To install locally:

```bash
# Kill running instance, copy to /Applications, relaunch
pkill -x ClaudeCodeStats; sleep 0.5
rm -rf /Applications/ClaudeCodeStats.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeCodeStats-*/Build/Products/Release/ClaudeCodeStats.app /Applications/
open /Applications/ClaudeCodeStats.app
```

There are no tests or linters configured.

## Architecture

- **App entry point**: `ClaudeCodeStatsApp.swift` — `MenuBarExtra` with chart icon, red dot badge overlay for updates
- **Main view**: `ContentView.swift` — contains the `UsageViewModel` (handles usage data + status polling) and all view components
- **Services** (singletons, async/await):
  - `WebSessionService` — fetches usage data from claude.ai API using session cookies
  - `StatusService` — fetches health status from status.claude.com
  - `VersionService` — checks installed CLI version (`claude --version` via Process) and latest release from GitHub API; includes `UpdateChecker` ObservableObject for state management

## Patterns

- Services are singletons with `static let shared` and private `init()`
- Non-critical features (status, version check) fail silently
- `@MainActor` on ObservableObjects, `@Published` for reactive state
- `@AppStorage` for persisted user preferences (e.g. dismissed update version)
- Auto-refresh timers: 5 min for usage, 1 hour for version checks
- The app sandbox is disabled (`com.apple.security.app-sandbox = false`)
- Colors are defined in `Theme.swift` (`Theme.background`, `Theme.cardBackground`, `Theme.textSecondary`, etc.) — always use `Theme.*` constants, never inline color literals or local computed properties
- Large SwiftUI `body` properties must be split into extracted computed properties (e.g. `menuBarDisplaySection`) — CI uses Xcode 16.2 whose Swift type-checker fails on complex single-body expressions that may compile locally on newer Xcode

## Xcode Project

When adding new `.swift` files, they must be added to `project.pbxproj` in four places:
1. `PBXBuildFile` section (build file reference, e.g. `A13`)
2. `PBXFileReference` section (file reference, e.g. `B15`)
3. The appropriate `PBXGroup` (Services or Views)
4. `PBXSourcesBuildPhase` files list

## Branch Naming

- `fix/<description>` — bug fixes (e.g. `fix/version-check-cancellation`)
- `<feature-name>` — new features and enhancements (e.g. `menubar`)

## Commit Style

Imperative mood, concise first line describing the change. Examples:
- `Add Claude Code version update detection`
- `Fix status indicator: nested buttons, missing timeout, dead code`
- `Clean up status indicator: consolidate logic, add concurrency guard`

## CI/CD

GitHub Actions workflow (`.github/workflows/release.yml`) triggers on release creation:
- Builds universal binary (arm64 + x86_64)
- Uploads ZIP to the GitHub release
- Updates the Homebrew tap (`dmelo/homebrew-tap`) with new version and SHA256
