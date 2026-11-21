# Multi-host spend: counting another machine's Claude Code usage

Status: **designed, partly de-risked, not implemented.** The 2026-09-18 transport spike showed ssh and rsync work when spawned from a Finder-launched bundle. It did **not** settle whether macOS's Local Network privilege will block the shipped app — see [Local Network privacy](#local-network-privacy-unresolved). No application code has been written.

The goal is what [ccmoneta](https://github.com/dmelo/ccmoneta) already does on Linux: mirror another machine's Claude Code transcripts locally and include them in this app's spend figures, so the totals cover every machine rather than whichever one you happen to be looking at.

## How ccmoneta does it (`src/sync.rs`, read at `eee5242`, 2026-09-17)

Per host from `[[sync.hosts]]` in its config:

1. `ssh -o BatchMode=yes -o ConnectTimeout=10 <host> "cd <dir> && find . -name '*.jsonl' -mtime -<days>"` (`days` defaults to 31).
2. Filter the listing to `./`-relative paths with no `..` component. Those names are handed to rsync *and* used to decide deletions, so a hostile or broken listing must not be able to name a path outside the mirror.
3. `rsync -a --files-from=<list> -e "ssh -o BatchMode=yes -o ConnectTimeout=10"` into `<cache>/hosts/<name>/projects/`. The `-e` matters: without it rsync starts its own ssh with no BatchMode (so it can try to prompt) and no connect timeout.
4. Delete local copies absent from the listing, then remove directories left empty.
5. Record `last-attempt` on every try, `last-sync` only on success, `last-error` on failure.

Three rules in there are worth copying verbatim, because each encodes a way to lose the mirror:

- **A failure deletes nothing.** Pruning runs only when *both* the ssh listing and rsync exited 0. A `find` that hits one unreadable directory prints a partial list and exits 1; pruning against that list would delete every transcript it happened to miss.
- **An empty listing prunes nothing.** "The host had no recent sessions" and "something upstream broke" produce the same empty list, and one of them would wipe the entire mirror.
- **A host is due by its last *attempt*, not its last success.** Counting successes retries an unreachable machine on every single refresh.

On the reading side ccmoneta comma-joins the host mirrors into one `CLAUDE_CONFIG_DIR` for a single ccusage run (`src/cost.rs`), so it relies on ccusage to parse and dedup them.

## What that maps to here

`CostService` parses transcripts and prices them itself, so there is no ccusage to invoke and no `CLAUDE_CONFIG_DIR` juggling: a mirrored host is simply another root.

- `CostService.transcriptPaths()` builds roots from `$CLAUDE_CONFIG_DIR` or `~/.claude` + `~/.config/claude`. Mirrored hosts become additional roots, each a directory containing `projects/`.
- **Adding roots alone needs no `cacheVersion` bump.** `cache.offsets` is keyed by absolute path, so mirrored transcripts get their own offsets and cannot collide with local ones. `prune()` already drops offsets for files that have gone away.
- **The mirror window must cover the chart window.** The spend card and chart show the last `chartWindowDays` (30) days, and a cold scan — first sync, or any `cacheVersion` bump — can only rebuild what is still in the mirror. So the per-host `-mtime -<days>` window must be at least `chartWindowDays + 1` (ccmoneta's default of 31 is exactly that). Enforce it as a floor, not a default: a shorter window undercounts that host, and after the next bump the missing days are gone.
- **Merging corpora is idempotent.** `ingest()` dedups on `message.id:requestId` and keeps the costliest copy, so a re-synced file, or the same machine mirrored twice, cannot double-count. (ccusage does the same, deduplicating on message ID + request ID across sessions — this is not an advantage over ccusage, only a reason we do not need it.)

### Per-host breakdown

This needs a `cacheVersion` bump, because it adds a `host` field to `EntryCost` and existing cached entries have none. It also needs an attribution rule, because dedup means one response can exist under two roots (a copied or resumed session, or one machine mirrored under two names). Today `ingest()` replaces the kept entry only when a later copy costs strictly more (`existing.cost >= cost` returns early), so on a tie the first path scanned wins, and scan order follows path spelling. Pick a stable rule instead — e.g. prefer the local root, then hosts in configured order — and apply it on ties, so a later sync cannot move an entry from one host to another.

## Transport spike, 2026-09-18

Ran a signed probe `.app` that spawns `ssh`/`rsync` through `Foundation.Process`, the same path `CostService` would use, logging to a file. It ran against a Linux machine, from a **Finder-launched** bundle. The `open`-from-a-shell version of this test is invalid because `open` passes the caller's whole environment; see the launch-environment trap in [../CLAUDE.md](../CLAUDE.md) (added in PR #37).

| Check | Result |
|---|---|
| `ssh -o BatchMode=yes` remote listing | exit 0, well under a second |
| `rsync -a --files-from=…` pull | exit 0, every listed transcript arrived |
| `ssh` / `rsync` resolvable on the minimal GUI `PATH` | yes — both live in `/usr/bin` |
| `SSH_AUTH_SOCK` in the 13-variable GUI environment | present (launchd provides it) |
| macOS Local Network alert | none appeared — which does **not** show the app is exempt; see below |

- macOS ships **openrsync** (`rsync version 2.6.9 compatible`) and it accepts `--files-from` as the pulling side. This was the main portability doubt.
- `BatchMode=yes` means the key must work without any prompt. That holds for a key with no passphrase, or one already loaded into launchd's own ssh-agent — the one `SSH_AUTH_SOCK` points to in a GUI launch. The spike verified only that the variable is present, not which setups work through it. Two cases likely fail and need a clear error in the UI: a passphrase key not yet loaded into that agent after a reboot, and keys held by an agent the user only exports from their shell (1Password, Secretive, gpg-agent), which the app cannot see unless `~/.ssh/config` sets `IdentityAgent`.
- Sizing, measured the same day: a month of transcripts from one active machine is a few hundred megabytes over several hundred files — comfortably within what a cold scan already handles locally, for both disk and CPU.

### Local Network privacy: unresolved

Apple's [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) contradicts the obvious reading of the spike. It says: *"if your app spawns a helper tool and the helper tool performs a local network operation, macOS considers the app to be the responsible code."* Its automatic allowances are launchd daemons, root, and *"Command-line tools run from Terminal or over SSH"* — not tools an app spawns. So the shipped app should expect its `/usr/bin/ssh` and `/usr/bin/rsync` to be blocked until the user grants it the Local Network privilege.

Two things in the same note explain why the spike saw no alert without contradicting that:

- *"A local network is an IP network associated with a broadcast-capable network interface. Such interfaces include Wi-Fi and Ethernet, but not cellular (WWAN) or VPN."* A host reached through a VPN or a routed hop is not a local network address at all.
- *"macOS fails to display the local network alert when a process with a very short lifespan performs a local network operation (FB16131937)."* The listing finished in well under a second.

Before building on this, re-run the spike against a host on the same Wi-Fi/Ethernet subnet with a longer-lived probe, and check System Settings › Privacy & Security › Local Network afterwards. Expect to need an `NSLocalNetworkUsageDescription` in `Info.plist` (the bundle has none today) and a UI state for "access denied".

## Design rules

- **Call `/usr/bin/ssh` and `/usr/bin/rsync` by absolute path, and pass rsync `-e "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10"`.** A GUI app's `PATH` depends entirely on who launched it, and the login case is the minimal one. Without `-e`, rsync starts `ssh` by a `PATH` lookup, so a Homebrew openssh ahead of `/usr/bin` would carry the transfer while `/usr/bin/ssh` carries the listing — a different agent and config handling (Apple's `UseKeychain` is an error there), failing only in development launches.
- **Keep sync off the refresh path, and bound it.** `UsageViewModel.refresh()` is single-flight (`guard !isLoading else { return }`) and awaits usage, status, spend and RTK in sequence; `CostService` is an actor. A transfer that hangs — the laptop sleeps or leaves Wi-Fi mid-rsync — would skip every later refresh or block the actor, freezing all the cards until relaunch. Run sync as its own task gated by last-attempt, with `-o ServerAliveInterval=15 -o ServerAliveCountMax=3` on ssh, `--timeout=60` on rsync, and a wall-clock cap that terminates the process. `CostService` only ever reads what the last completed sync left on disk.
- **Do not let the mirror follow links out of itself.** The `..` filter protects only the listing's path names; `rsync -a` implies `-l`, so a remote symlink named `*.jsonl` would be recreated in the mirror, and `CostService`'s enumerator would read whatever local file it points to. Pass `--no-links` — macOS openrsync accepts it despite leaving it out of `--help`, and with `--files-from` it skips both absolute and relative links (checked local-to-local on 2026-09-28, not yet against a remote sender) — and skip symlinks in `transcriptPaths()` for mirror roots as a second line.
- **The mirror lives in `~/Library/Caches/<bundle id>/hosts/<name>/projects/`**, not Application Support. It is re-derivable and a few hundred megabytes per host; Caches keeps it out of Time Machine and migration, and macOS may purge it, which the next sync simply refills.

## Open, if this gets built

- Where hosts are configured. This app has no config file; ccmoneta has TOML. `@AppStorage` plus a Settings pane is the idiomatic answer here.
- Whether to sync while the app is closed. ccmoneta offers a systemd timer; the macOS equivalent is a LaunchAgent — which TN3179 notes is *not* covered by the launchd-daemon allowance — but a menu bar app that is always running can drive sync from its own timer, off the refresh path as above.
