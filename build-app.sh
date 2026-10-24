#!/bin/zsh
# Builds AgentIsland.app (with the `island` CLI inside) next to this script.
# `./build-app.sh --install` also replaces /Applications/AgentIsland.app and restarts it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="AgentIsland.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
cp "$BIN/island" "$APP/Contents/MacOS/island"
mkdir -p "$APP/Contents/Resources"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agent Island</string>
    <key>CFBundleDisplayName</key><string>Agent Island</string>
    <key>CFBundleIdentifier</key><string>local.agent-island</string>
    <key>CFBundleExecutable</key><string>AgentIsland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Agent Island selects the terminal tab running the agent you clicked.</string>
</dict>
</plist>
PLIST

# Copied or downloaded files can carry Finder metadata that codesign rejects.
xattr -cr "$APP"

# Ad-hoc signing normally ties macOS permissions (Accessibility, Automation) to this exact build.
# Pinning the designated requirement to the bundle id keeps them across rebuilds.
codesign --force --sign - --identifier local.agent-island.cli "$APP/Contents/MacOS/island"
codesign --force --sign - --requirements '=designated => identifier "local.agent-island"' "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -f "AgentIsland.app/Contents/MacOS/AgentIsland" || true
    sleep 1
    rm -rf /Applications/AgentIsland.app
    ditto "$APP" /Applications/AgentIsland.app
    open /Applications/AgentIsland.app
    # Agent hooks run their own copy of the CLI; keep it in step with the app.
    mkdir -p "$HOME/.agent-island/bin"
    cp "$APP/Contents/MacOS/island" "$HOME/.agent-island/bin/island"
    echo "Installed /Applications/AgentIsland.app and ~/.agent-island/bin/island"
fi
