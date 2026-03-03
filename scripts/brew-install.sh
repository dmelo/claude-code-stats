#!/bin/bash
set -e

echo "Stopping local install..."
pkill -x ClaudeCodeStats 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/ClaudeCodeStats.app

echo "Updating tap..."
brew update

echo "Installing latest from Homebrew..."
brew reinstall dmelo/tap/claude-code-stats

echo "Launching..."
open /Applications/ClaudeCodeStats.app
echo "Done."
