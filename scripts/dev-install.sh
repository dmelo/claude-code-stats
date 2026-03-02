#!/bin/bash
set -e

cd "$(dirname "$0")/../ClaudeCodeStats"

echo "Building..."
xcodebuild -scheme ClaudeCodeStats -configuration Release build 2>&1 | tail -3

echo "Installing to /Applications..."
pkill -x ClaudeCodeStats 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/ClaudeCodeStats.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeCodeStats-*/Build/Products/Release/ClaudeCodeStats.app /Applications/

echo "Launching..."
open /Applications/ClaudeCodeStats.app
echo "Done."
