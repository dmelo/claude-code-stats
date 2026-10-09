#!/bin/bash
# Mirror another machine's Claude Code transcripts onto this Mac, so Claude Code
# Stats includes that machine's API-equivalent spend.
#
# The app's spend scan already reads ~/.config/claude/projects alongside
# ~/.claude/projects (when CLAUDE_CONFIG_DIR is unset), and Claude Code on macOS
# does not use ~/.config/claude, so a mirror there is counted by the app without
# Claude Code ever seeing it. Each host gets its own subfolder. Spend dedups on
# message id + request id, so syncing the same file again never double-counts.
#
#   sync-host-transcripts.sh sync <host> [remote-dir]       one sync, now
#   sync-host-transcripts.sh install <host> [remote-dir] [interval-seconds]
#   sync-host-transcripts.sh uninstall <host>
#
# <host> is anything `ssh <host>` accepts (an alias from ~/.ssh/config works).
# [remote-dir] is relative to the remote home; default .claude/projects.
# The key must work without a prompt: ssh runs with BatchMode=yes.
set -euo pipefail

SSH=/usr/bin/ssh
RSYNC=/usr/bin/rsync
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
# The spend chart covers 30 days; a cold rescan can only rebuild what is still
# mirrored, so copy one day more than that.
LIST_DAYS=31
# Local copies are pruned by age only, never by what the listing omits, so a
# broken or partial listing can't delete anything recent.
KEEP_DAYS=35
MIRROR_ROOT="$HOME/.config/claude/projects"
SUPPORT_DIR="$HOME/Library/Application Support/ClaudeCodeStats"
LOG_DIR="$HOME/Library/Logs/ClaudeCodeStats"
LABEL_PREFIX=com.claudecodestats.sync

usage() {
    sed -n '11,13p' "$0" | sed 's/^# *//'
    exit 2
}

# Host and remote dir end up in a remote shell command and in file names, so
# allow only characters that need no quoting anywhere.
check_name() {
    case "$1" in
        ''|*[!A-Za-z0-9._@-]*) echo "invalid host: $1" >&2; exit 2 ;;
    esac
}

check_remote_dir() {
    case "$1" in
        ''|/*|*..*|*[!A-Za-z0-9._/-]*) echo "invalid remote dir: $1" >&2; exit 2 ;;
    esac
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

sync_host() {
    local host=$1 remote_dir=${2:-.claude/projects}
    check_name "$host"
    check_remote_dir "$remote_dir"
    local dest="$MIRROR_ROOT/$host"
    # Globals, not locals: the EXIT trap runs after this function has returned.
    RAW_LIST=$(mktemp)
    FILE_LIST=$(mktemp)
    trap 'rm -f "$RAW_LIST" "$FILE_LIST"' EXIT
    local raw=$RAW_LIST list=$FILE_LIST

    # A failed listing changes nothing locally.
    # shellcheck disable=SC2086
    if ! "$SSH" $SSH_OPTS "$host" "cd $remote_dir && find . -type f -name '*.jsonl' -mtime -$LIST_DAYS" > "$raw"; then
        log "$host: listing failed, nothing changed"
        return 1
    fi
    # These names go to rsync, so keep only ./-relative paths with no `..`.
    grep -E '^\./' "$raw" | grep -vE '(^|/)\.\.(/|$)' > "$list" || true
    if [ ! -s "$list" ]; then
        log "$host: no transcripts in the last $LIST_DAYS days, nothing changed"
        return 0
    fi

    mkdir -p "$dest"
    # --no-links: a remote symlink named *.jsonl must not become a local link
    # the spend scan would follow. -e pins rsync's own ssh to the same binary
    # and options as the listing.
    if ! "$RSYNC" -a --no-links --timeout=60 --files-from="$list" \
            -e "$SSH $SSH_OPTS" "$host:$remote_dir/" "$dest/"; then
        log "$host: rsync failed, nothing pruned"
        return 1
    fi

    find "$dest" -type f -name '*.jsonl' -mtime +$KEEP_DAYS -delete
    find "$dest" -mindepth 1 -type d -empty -delete
    log "$host: synced $(wc -l < "$list" | tr -d ' ') transcripts"
}

plist_path() {
    echo "$HOME/Library/LaunchAgents/$LABEL_PREFIX.$1.plist"
}

install_agent() {
    local host=$1 remote_dir=${2:-.claude/projects} interval=${3:-900}
    check_name "$host"
    check_remote_dir "$remote_dir"
    case "$interval" in ''|*[!0-9]*) echo "invalid interval: $interval" >&2; exit 2 ;; esac

    # Run from a fixed copy, so moving or deleting the repo checkout doesn't
    # break the agent.
    mkdir -p "$SUPPORT_DIR" "$LOG_DIR"
    local script="$SUPPORT_DIR/sync-host-transcripts.sh"
    cp "$0" "$script"
    chmod 755 "$script"

    local label="$LABEL_PREFIX.$host" plist
    plist=$(plist_path "$host")
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$script</string>
        <string>sync</string>
        <string>$host</string>
        <string>$remote_dir</string>
    </array>
    <key>StartInterval</key>
    <integer>$interval</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/sync-$host.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/sync-$host.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "Installed $label: every ${interval}s, log at $LOG_DIR/sync-$host.log"
}

uninstall_agent() {
    local host=$1
    check_name "$host"
    launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$host" 2>/dev/null || true
    rm -f "$(plist_path "$host")"
    echo "Removed the $host agent. The mirror is left in place: rm -rf \"$MIRROR_ROOT/$host\" to drop it from spend."
}

case "${1:-}" in
    sync) [ $# -ge 2 ] || usage; sync_host "$2" "${3:-}" ;;
    install) [ $# -ge 2 ] || usage; install_agent "$2" "${3:-}" "${4:-}" ;;
    uninstall) [ $# -eq 2 ] || usage; uninstall_agent "$2" ;;
    *) usage ;;
esac
