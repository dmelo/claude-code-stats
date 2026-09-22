# Multi-host spend: counting another machine's Claude Code usage

Status: **designed and de-risked, not implemented** (2026-09-18). The transport
spike passed; no application code has been written.

The goal is what [ccmoneta](https://github.com/dmelo/ccmoneta) already does on
Linux: mirror another machine's Claude Code transcripts locally and include
them in this app's spend figures, so the totals cover every machine rather than
whichever one you happen to be looking at.

## How ccmoneta does it (`src/sync.rs`, read at commit of 2026-09-17)

Per host from `[[sync.hosts]]` in its config:

1. `ssh -o BatchMode=yes -o ConnectTimeout=10 <host> "cd <dir> && find . -name '*.jsonl' -mtime -<days>"`
2. Filter the listing to `./`-relative paths with no `..` component. Those names
   are handed to rsync *and* used to decide deletions, so a hostile or broken
   listing must not be able to name a path outside the mirror.
3. `rsync -a --files-from=<list>` into `<cache>/hosts/<name>/projects/`
4. Delete local copies absent from the listing.
5. Record `last-attempt` on every try, `last-sync` only on success, `last-error`
   on failure.

Two rules in there are worth copying verbatim, because both encode a failure
that already happened to someone:

- **An empty listing prunes nothing.** "The host had no recent sessions" and
  "something upstream broke" produce the same empty list, and one of them would
  wipe the entire mirror.
- **A host is due by its last *attempt*, not its last success.** Counting
  successes retries an unreachable machine on every single render.

On the reading side ccmoneta runs one `ccusage` per host with `CLAUDE_CONFIG_DIR`
pointed at that host's mirror, and sums the per-host daily reports locally — so
the per-host numbers add up to the header by construction.

## What that maps to here

This app does **not** need most of the above. `CostService` parses transcripts
and prices them itself, so there is no ccusage to invoke and no
`CLAUDE_CONFIG_DIR` juggling: a mirrored host is simply another root.

- `CostService.transcriptPaths()` builds roots from `$CLAUDE_CONFIG_DIR` or
  `~/.claude` + `~/.config/claude`. Mirrored hosts become additional roots,
  each a directory containing `projects/`.
- **Adding roots alone needs no `cacheVersion` bump.** `cache.offsets` is keyed
  by absolute path, so mirrored transcripts get their own offsets and cannot
  collide with local ones. `prune()` already drops offsets for files that have
  gone away, which matches the mirror's own pruning.
- **A per-host breakdown does need a bump**, because it means adding a `host`
  field to `EntryCost` and existing cached entries have no such field.
- `ingest()` dedups on `message.id:requestId` and keeps the costliest copy, so
  merging corpora is idempotent: a re-synced file, or the same machine mirrored
  twice, cannot double-count. ccusage has no equivalent guard.

## Transport spike, 2026-09-18 — passed

Ran a signed probe `.app` that spawns `ssh`/`rsync` through `Foundation.Process`,
the same path `CostService` would use, logging to a file.

Against a Linux machine on the local network, from a **Finder-launched** bundle —
see the launch-environment trap in [../CLAUDE.md](../CLAUDE.md); the
`open`-from-a-shell version of this test is invalid, because it inherits the
caller's environment:

| Check | Result |
|---|---|
| `ssh -o BatchMode=yes` remote listing | exit 0, well under a second |
| `rsync -a --files-from=…` pull | exit 0, every listed transcript arrived |
| `ssh` / `rsync` resolvable on the minimal GUI `PATH` | yes — both live in `/usr/bin` |
| `SSH_AUTH_SOCK` in the 13-variable GUI environment | present (launchd provides it) |
| macOS Local Network TCC prompt | none blocked it, on a bundle ID never granted anything |

Notes on each:

- macOS ships **openrsync** (`rsync version 2.6.9 compatible`) and it accepts
  `--files-from` as the pulling side. This was the main portability doubt.
- `BatchMode=yes` needs no agent at all for a key with no passphrase. Since
  `SSH_AUTH_SOCK` is present in the GUI environment regardless, a
  passphrase-protected key held in an agent works too.
- Spawning `/usr/bin/ssh` appears to attribute the network connection to that
  system binary rather than to the app, which is why no local-network prompt
  appeared. Re-check this if the app ever opens a LAN socket itself.

Sizing, measured the same day: a month of transcripts from one active machine
is a few hundred megabytes over several hundred files — comfortably within what
a cold scan already handles locally, for both disk and CPU.

## The one design rule the spike produced

Call `/usr/bin/ssh` and `/usr/bin/rsync` by **absolute path**. A GUI app's
`PATH` depends entirely on who launched it, and the login case is the minimal
one. See ../CLAUDE.md.

## Open, if this gets built

- Where the mirror lives — Application Support alongside `cost_cache.json`, or
  a cache directory.
- Where hosts are configured. This app has no config file; ccmoneta has TOML.
  `@AppStorage` plus a Settings pane is the idiomatic answer here.
- Whether to sync while the app is closed. ccmoneta offers a systemd timer; the
  macOS equivalent is a LaunchAgent, but a menu bar app that is always running
  can just drive it from the existing refresh timer.
