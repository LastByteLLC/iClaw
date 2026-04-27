# Browser Extensions & Native Messaging

iClaw communicates with Safari, Chrome, and Firefox via a localhost TLS bridge. This directory contains the cross-browser extension sources and the native messaging host installer.

## Directory layout

```
Extension/
├── background.js           # MV3 service worker (entry point)
├── popup/                  # Popup UI (Send Page, status)
├── content/                # Content scripts (page extraction)
├── shared/                 # compat.js, protocol.js (globalThis-based)
├── safari/                 # Safari-specific: SafariWebExtensionHandler.swift, Info.plist, entitlements
├── manifests/              # Per-browser manifest.json (Chrome, Firefox)
├── icons/                  # Toolbar / store icons
├── share/
└── install-native-host.sh  # Registers the native messaging host for Chrome/Firefox
```

## Architecture

```
Safari:   popup/background.js → browser.runtime.sendNativeMessage()
              → SafariWebExtensionHandler.beginRequest(with:)
              → TCP localhost:19284 (TLS) → BrowserBridge

Chrome:   popup/background.js → browser.runtime.connectNative()
              → iClawNativeHost (stdin/stdout)
              → TCP localhost:19284 (TLS) → BrowserBridge

Firefox:  Same as Chrome
```

**Transport:** `BrowserBridge` (see `Sources/iClawCore/Bridge/BrowserBridge.swift`) listens on `localhost:19284` using TLS with a self-signed P-256 identity stored in the Keychain (`BridgeTLS.swift`). Fallback to a random OS-assigned port if the well-known port is taken. No App Group container, no port file — this avoids macOS Sequoia's container protection dialog.

## Build

- **Safari extension** (`.appex`): Built by Xcode target `iClawSafariExtension`. `make release` runs `xcodebuild -target iClawSafariExtension` and copies the `.appex` into `Contents/PlugIns/` of the app bundle.
- **Native messaging host**: `swift build --product iClawNativeHost`. Register manifests via `./install-native-host.sh`.
- **Chrome / Firefox extension**: Load this `Extension/` directory unpacked. Manifests in `manifests/`.

## Two communication flows

- **Pull (iClaw → browser)** — `BrowserBridgeFetchBackend` sends `page.getContent` / `page.navigate` requests via `BrowserBridge.request()`. Chrome/Firefox use the persistent `connectNative()` port. Safari pull is not yet implemented.
- **Push (browser → iClaw)** — popup's "Send Page to iClaw" button extracts page content and pushes it. Safari uses `sendNativeMessage()` → `SafariWebExtensionHandler` → TCP. The bridge routes received push data into the execution pipeline.

## Safari gotchas

- **The host app must be sandboxed** (`ENABLE_APP_SANDBOX = YES`). Safari will not list the extension in Settings → Extensions otherwise.
- **App Group prefix** — IDs must use the Team ID prefix (e.g. `5QGXMKNW2A.com.geticlaw.iClaw`), **not** the iOS `group.` prefix. The `group.` convention triggers macOS Sequoia's "access data from other apps" dialog. The App Group is retained for `MailHookManager` only; the bridge does not need it.
- **`ENABLE_INCOMING_NETWORK_CONNECTIONS = YES`** is required for the TLS listener.
- **Resources must be individual file references** in Xcode (Create Groups), NOT a folder reference. A folder reference nests them under `Contents/Resources/Resources/` which Safari silently rejects. Correct layout: `Contents/Resources/manifest.json`.
- **`background.js` is a Manifest V3 service worker** with `"type": "module"` in `manifest.json`. Shared scripts (`compat.js`, `protocol.js`) use `globalThis` assignment (not `export`) so they work both as ES module side-effect imports and as plain `<script>` tags in popup/content scripts.
- **"Allow Unsigned Extensions"** in Safari's Develop menu resets every Safari session — re-enable after each Safari restart for dev builds.
- **Provisioning profile** — the extension profile must include the App Group. After adding the group, Xcode needs to regenerate profiles (may require device registration via the GUI).

## Related source

- `Sources/iClawCore/Bridge/BrowserBridge.swift` — TLS listener, message framing, request/response
- `Sources/iClawCore/Bridge/BridgeTLS.swift` — self-signed P-256 identity in Keychain
- `Sources/iClawCore/Bridge/BrowserMonitor.swift` — connection state / UI indicator
- `Sources/iClawNativeHost/main.swift` — Chrome/Firefox native messaging host binary
- `Sources/iClawCore/Tools/Fetch/` — `FetchBackend`, including `BrowserBridgeFetchBackend`
