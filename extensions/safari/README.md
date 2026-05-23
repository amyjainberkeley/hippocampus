# Hippocampus Safari Web Extension

Safari Web Extension that captures page content (URL, title, body text) and
forwards it to the Hippocampus container app via App Groups. All data stays
on-device.

## Architecture

```
Safari
 └─ content.js  (extracts page text, sends to background)
     └─ background.js  (receives page_content, calls sendNativeMessage)
         └─ SafariWebExtensionHandler.swift  (.appex, receives native message)
             └─ App Group shared container  (group.ai.hippocampus)
                 └─ Hippocampus.app reads safari-inbox/ → mci-agent
```

Unlike the Chromium extension (which uses stdio native messaging), Safari Web
Extensions route native messages through a `SafariWebExtensionHandler` class
inside the `.appex` bundle. The handler writes each message as a JSON file to
the App Group shared container (`group.ai.hippocampus/safari-inbox/`), where
the container app picks it up.

## Bundle structure

```
Hippocampus.app/
  Contents/
    PlugIns/
      HippocampusSafariExtension.appex/
        Contents/
          Info.plist
          MacOS/
            HippocampusSafariExtension
          Resources/
            manifest.json
            background.js
            content.js
```

## Building

The `.appex` is built automatically by `build-app.sh`:

```bash
cd apps/hippocampus
swift build -c release
# (also build MCICaptureHelper and mci-agent per build-app.sh --help)
./Resources/build-app.sh
```

The script compiles `SafariWebExtensionHandler.swift`, assembles the `.appex`
bundle, and embeds it in `Hippocampus.app/Contents/PlugIns/`.

## Enabling in Safari

1. Build and launch `Hippocampus.app` (must be codesigned — ad-hoc is fine for
   local dev, but Developer ID is required for distribution).
2. Open **Safari → Settings → Extensions** (⌘,).
3. Check **Hippocampus** in the extension list.
4. Grant permission when prompted ("Allow for one day" / "Always allow on
   every website" / per-site).

The extension appears in the list because Safari discovers `.appex` bundles
with `NSExtensionPointIdentifier = com.apple.Safari.web-extension` inside
running app bundles.

## Testing

```bash
# Verify .appex is embedded correctly
ls Hippocampus.app/Contents/PlugIns/HippocampusSafariExtension.appex/

# Verify Info.plist
plutil -lint Hippocampus.app/Contents/PlugIns/HippocampusSafariExtension.appex/Contents/Info.plist

# Verify codesigning
codesign -dvvv Hippocampus.app/Contents/PlugIns/HippocampusSafariExtension.appex

# Verify web extension resources are present
ls Hippocampus.app/Contents/PlugIns/HippocampusSafariExtension.appex/Contents/Resources/
```

To test the full flow: enable the extension in Safari, visit a page, then
check for JSON files in the App Group container:

```bash
ls ~/Library/Group\ Containers/group.ai.hippocampus/safari-inbox/
```

## Private Browsing

Safari disables extensions in Private Browsing windows by default. Users must
explicitly opt in via Safari → Settings → Extensions → Hippocampus → "Allow
in Private Browsing". This matches the CSO-required incognito-exclusion
invariant from the Chromium extension's `"incognito": "split"` manifest key.

## Known limitations

- **App Group container reader not yet wired**: the container app does not yet
  poll `safari-inbox/` to forward messages to mci-agent. This is the next
  integration step.
- **No persistent native messaging port**: Safari Web Extensions only support
  one-shot `sendNativeMessage`, not `connectNative`. Each page content event
  is an independent message → file write.
- **Developer ID required for distribution**: Safari will not load unsigned
  `.appex` bundles outside of local development.
- **No icon yet**: the extension uses Safari's default extension icon. A proper
  toolbar icon should be added to the manifest and Resources.
