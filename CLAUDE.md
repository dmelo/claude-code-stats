# CLAUDE.md

## Project Overview

ClaudeCodeStats is a native macOS menu bar app (SwiftUI) that shows Claude Code usage limits, Claude service health status, and CLI version update notifications.

## Build

```bash
cd ClaudeCodeStats
xcodebuild -scheme ClaudeCodeStats -configuration Release build
```

The built `.app` is in `~/Library/Developer/Xcode/DerivedData/ClaudeCodeStats-<hash>/Build/Products/Release/`.

**Resolve that path explicitly — never with a `ClaudeCodeStats-*` glob.** Xcode keeps a
separate DerivedData directory per project location, and stale ones are not cleaned up. When
more than one exists the glob expands to all of them, so `cp -R src1 src2 /Applications/`
copies the fresh build and then **overwrites it with the stale one**, exit 0 and no warning —
you end up debugging a binary that is weeks old. `ls -dt` does not save you either: it sorts
by directory mtime, which a previous `cp` will have touched. The last line `xcodebuild` prints
(`lsregister -f -R -trusted <path>`) names the directory it actually built into.

To install locally:

```bash
# Take the path from xcodebuild's own output, or pick by the *binary's* mtime:
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/ClaudeCodeStats-*/Build/Products/Release/ClaudeCodeStats.app/Contents/MacOS/ClaudeCodeStats \
      | head -1 | sed 's#/Contents/MacOS/ClaudeCodeStats##')
echo "installing from: $APP"   # sanity-check this before continuing

# Kill running instance, copy to /Applications, relaunch
pkill -x ClaudeCodeStats; sleep 0.5
rm -rf /Applications/ClaudeCodeStats.app
cp -R "$APP" /Applications/ClaudeCodeStats.app
open /Applications/ClaudeCodeStats.app
```

If a change you just made doesn't show up, check this first: a rendered colour or string that
exists nowhere in the source tree means you are not running the tree.

There are no tests or linters configured, so verifying a change means running the app and looking at it. Five non-obvious traps when doing that from a shell:

- **Launch with `open`, never `&`.** A `.app` started as `"$BINARY" &` from a Bash tool dies when that shell returns, often mid-work — `open /Applications/ClaudeCodeStats.app` hands it to LaunchServices so it survives. To time a scan or wait on a side effect, poll the artifact (`until [ -f "$cost_cache" ]; do sleep 2; done`), don't hold the process open.
- **`open` from a shell does NOT reproduce how the app starts at login — it passes the caller's whole environment.** Measured 2026-09-18 with a probe app that logged its own env: launched by `open` from a Bash tool it saw 77 variables and the full interactive `PATH`, including this session's `~/.claude/plugins/cache/...` entries; the same bundle launched from Finder saw **13 variables and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`**. The running `ClaudeCodeStats.app` inherits whatever its launcher had, so during development it usually has the rich one. Anything the app shells out to must therefore be called by **absolute path** (`/usr/bin/ssh`, not `ssh`) — a `PATH`-dependent subprocess works all through development and breaks the first time the app starts at login. To test a real launch environment, `osascript -e 'tell application "Finder" to open POSIX file "…"'`, never `open`.
- **A quarantined copy launches, allocates its status item, and draws NOTHING.** Verified 2026-09-18 on v0.12.2 installed by `brew upgrade`: the process ran (`uiElement=1`, no crash, all three ring toggles on) and the menu bar showed no item — yet the log carried `Alloc com.apple.controlcenter.statusitems`, and the neighbouring icons sat at the *same* x with the app running or killed, so the item was present and reserving its ~108px slot while rendering blank. The single variable is `com.apple.quarantine`, which Homebrew leaves on the download; clearing it on the same bytes at the same path fixes it instantly: `xattr -dr com.apple.quarantine /Applications/ClaudeCodeStats.app`. Isolate before blaming a release — run the extracted release ZIP de-quarantined and the local DerivedData build; both rendered fine, which is what ruled the CI build out. Note v0.12.1 from brew did **not** do this on 2026-09-04, so treat it as environment-dependent rather than a fixed property of a version. The app is ad-hoc signed (`Signature=adhoc`, `TeamIdentifier=not set`), which is what leaves it exposed; Developer ID + notarization is the durable fix.
- **Instrument to a file, not stderr.** A menu bar app has no attached terminal, and one you'll `pkill` loses buffered stdout/stderr — write debug lines to a file (`/tmp/…`) and `cat` it after.
- **AppleScript can't open the MenuBarExtra popover** (`click menu bar item …` does nothing). To inspect a view in a specific state or appearance without the running app, compile the real views into a standalone `ImageRenderer` harness and render at a chosen `\.colorScheme` + sample data (`swiftc main.swift Theme.swift Models.swift Views/*.swift` — top-level code needs the file named `main.swift`). It renders everything except `ScrollView` content, which comes back blank.

**`strings` on the built binary cannot prove a Swift literal is absent.** Swift stores strings of **≤15 UTF-8 bytes** inline in the struct rather than in `__TEXT`, so they never appear in `strings` output — verified 2026-09-18 across 16 literals in the shipped v0.12.2, where the correlation was exact: every prefix ≥16 bytes showed up, every shorter one did not unless it happened to be a substring of a longer one. This nearly produced a false "Fable 5.1 / Mythos 5.1 / Opus 4.5 are MISSING from the release" report. Absence there is the instrument's blind spot, not evidence; verify a release by the ZIP↔cask↔installed-binary SHA chain plus the source at the tag instead.

`CostService` spend is validated against `npx ccusage` — but ccusage and a fresh scan **must be measured at the same instant**. A live corpus grows every few seconds while Claude Code runs, so a scan compared against a ccusage snapshot from minutes earlier shows a false delta (this produced a confidently-wrong "0.7% residual" that was pure skew; measured together, they agree to the cent on unused models).

## Architecture

- **App entry point**: `ClaudeCodeStatsApp.swift` — `MenuBarExtra` with chart icon, red dot badge overlay for updates
- **Main view**: `ContentView.swift` — contains the `UsageViewModel` (handles usage data + status polling) and all view components
- **Services** (singletons, async/await):
  - `OAuthUsageService` — fetches usage data from the Anthropic `GET /api/oauth/usage` endpoint using OAuth credentials (reads `~/.claude/.credentials.json` first, falls back to macOS Keychain `Claude Code-credentials`), decoding session, weekly all-models, and per-model scoped weekly limits (e.g. Fable) from the JSON `limits` array
  - `CostService` — computes API-equivalent spend by scanning the Claude Code transcripts in `~/.claude/projects/**/*.jsonl`. An `actor`, not a `@MainActor` singleton: a cold scan parses the entire corpus (gigabytes, seconds of CPU) and has to stay off the main thread. Caches per-day rollups in Application Support and resumes each transcript from a byte offset, so a warm refresh re-reads only what was appended — usually nothing, and it then skips the cache write too. Any change to its price table, cost formula, or parsing **must** bump `cacheVersion` — costs are priced once at scan time and offsets advance regardless, so otherwise the change is silently ignored. **The authority for the price table is the CLI's own baked model catalogue, not the models seen in transcripts so far**: `strings "$(readlink -f "$(which claude)")" | grep -o 'pricing_tiers.*'` yields every model id, `display_name` and pricing tier the CLI can write, and Anthropic's published pricing page agrees with it row for row. Enumerating from consumers instead is what let Fable 5.1, the whole Mythos family and the retired 4.x/3.x ids go missing. Two shapes to watch, both found live in v0.12.1: prefixes nest (`claude-fable-5` matches `claude-fable-5-1`, so first-match lookup **misprices** a point release instead of skipping it — the table is sorted longest-prefix-first for this reason), and a bare prefix like `claude-opus-4` is a catch-all for releases that do not exist yet. Cache-read multipliers are per-model, not global: Fable/Mythos 5.1 read at 0.025× where everything else reads at 0.1×
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
