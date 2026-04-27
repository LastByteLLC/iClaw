#!/bin/bash
# Install iClaw native messaging host manifests for Chrome, Firefox, and Chromium.
# Usage: ./install-native-host.sh [path-to-iClawNativeHost-binary]
#
# Safari uses its own app extension mechanism — no manifest needed.

set -e

BINARY="${1:-$(dirname "$0")/../.build/debug/iClawNativeHost}"
BINARY=$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")

if [ ! -f "$BINARY" ]; then
    echo "Error: iClawNativeHost binary not found at: $BINARY"
    echo "Build it first: swift build --product iClawNativeHost"
    exit 1
fi

# TODO: Replace with actual Chrome extension ID after publishing to Chrome Web Store
CHROME_EXT_ID="PLACEHOLDER_CHROME_EXTENSION_ID"
FIREFOX_EXT_ID="hello@last-byte.org"
HOST_NAME="com.geticlaw.nativehost"

# ─── Chrome manifest ───
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$CHROME_DIR"
cat > "$CHROME_DIR/$HOST_NAME.json" << EOF
{
  "name": "$HOST_NAME",
  "description": "iClaw Native Messaging Host",
  "path": "$BINARY",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$CHROME_EXT_ID/"
  ]
}
EOF
echo "Installed Chrome manifest: $CHROME_DIR/$HOST_NAME.json"

# ─── Chromium manifest ───
CHROMIUM_DIR="$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
mkdir -p "$CHROMIUM_DIR"
cp "$CHROME_DIR/$HOST_NAME.json" "$CHROMIUM_DIR/$HOST_NAME.json"
echo "Installed Chromium manifest: $CHROMIUM_DIR/$HOST_NAME.json"

# ─── Firefox manifest ───
FIREFOX_DIR="$HOME/.mozilla/native-messaging-hosts"
mkdir -p "$FIREFOX_DIR"
cat > "$FIREFOX_DIR/$HOST_NAME.json" << EOF
{
  "name": "$HOST_NAME",
  "description": "iClaw Native Messaging Host",
  "path": "$BINARY",
  "type": "stdio",
  "allowed_extensions": [
    "$FIREFOX_EXT_ID"
  ]
}
EOF
echo "Installed Firefox manifest: $FIREFOX_DIR/$HOST_NAME.json"

echo ""
echo "Done. Native messaging host installed for Chrome, Chromium, and Firefox."
echo "Binary: $BINARY"
echo ""
echo "Next steps:"
echo "  1. Load the extension in your browser (chrome://extensions or about:debugging)"
echo "  2. Make sure iClaw is running"
echo "  3. Click the iClaw extension icon to connect"
