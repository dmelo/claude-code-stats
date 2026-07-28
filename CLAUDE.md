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

There are no tests or linters configured, so verifying a change means running the app and looking at it. Three non-obvious traps when doing that from a shell:

- **Launch with `open`, never `&`.** A `.app` started as `"$BINARY" &` from a Bash tool dies when that shell returns, often mid-work — `open /Applications/ClaudeCodeStats.app` hands it to LaunchServices so it survives. To time a scan or wait on a side effect, poll the artifact (`until [ -f "$cost_cache" ]; do sleep 2; done`), don't hold the process open.
- **Instrument to a file, not stderr.** A menu bar app has no attached terminal, and one you'll `pkill` loses buffered stdout/stderr — write debug lines to a file (`/tmp/…`) and `cat` it after.
- **AppleScript can't open the MenuBarExtra popover** (`click menu bar item …` does nothing). To inspect a view in a specific state or appearance without the running app, compile the real views into a standalone `ImageRenderer` harness and render at a chosen `\.colorScheme` + sample data (`swiftc main.swift Theme.swift Models.swift Views/*.swift` — top-level code needs the file named `main.swift`). It renders everything except `ScrollView` content, which comes back blank.

`CostService` spend is validated against `npx ccusage` — but ccusage and a fresh scan **must be measured at the same instant**. A live corpus grows every few seconds while Claude Code runs, so a scan compared against a ccusage snapshot from minutes earlier shows a false delta (this produced a confidently-wrong "0.7% residual" that was pure skew; measured together, they agree to the cent on unused models).

## Architecture

- **App entry point**: `ClaudeCodeStatsApp.swift` — `MenuBarExtra` with chart icon, red dot badge overlay for updates
- **Main view**: `ContentView.swift` — contains the `UsageViewModel` (handles usage data + status polling) and all view components
- **Services** (singletons, async/await):
  - `OAuthUsageService` — fetches usage data from the Anthropic `GET /api/oauth/usage` endpoint using OAuth credentials (reads `~/.claude/.credentials.json` first, falls back to macOS Keychain `Claude Code-credentials`), decoding session, weekly all-models, and per-model scoped weekly limits (e.g. Fable) from the JSON `limits` array
  - `CostService` — computes API-equivalent spend by scanning the Claude Code transcripts in `~/.claude/projects/**/*.jsonl`. An `actor`, not a `@MainActor` singleton: a cold scan parses the entire corpus (gigabytes, seconds of CPU) and has to stay off the main thread. Caches per-day rollups in Application Support and resumes each transcript from a byte offset, so a warm refresh re-reads only what was appended — usually nothing, and it then skips the cache write too. Any change to its price table, cost formula, or parsing **must** bump `cacheVersion` — costs are priced once at scan time and offsets advance regardless, so otherwise the change is silently ignored
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
