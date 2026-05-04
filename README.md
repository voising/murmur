# Murmur

**Voice-to-text on any Mac. Even your old Intel one.**

Most dictation apps that don't suck need Apple Silicon to run a local Whisper model. Murmur doesn't — it streams audio to Groq's hosted Whisper, so transcription is fast even on a 2018 MacBook Pro. No Neural Engine, no 8GB model download, no fans spinning up.

Hold right-Option, talk, release. The text appears wherever your cursor is. That's it.

Powered by [Groq](https://console.groq.com) + Whisper.

## Requirements

- macOS 13 (Ventura) or later
- A free [Groq API key](https://console.groq.com)
- Xcode 15+ (full Xcode, not just command-line tools — required for the AppKit/SwiftUI macOS toolchain)

## Build & install

```sh
bash scripts/build.sh
cp -R .build/Murmur.app /Applications/
open /Applications/Murmur.app
```

On first launch you'll be prompted for:

1. **Microphone access** — to capture your voice
2. **Accessibility access** — so the right-Option hotkey and auto-paste work
3. Your **Groq API key** — stored in macOS Keychain

## Usage

- **Record**: press and hold right-Option (`⌥`)
- **Transcribe + paste**: release the key
- **Menu bar**: click the mic icon for launch-at-login, key management, help

## Development

```sh
swift build            # debug build
swift run              # run from terminal (note: no .app bundle → no icon / Info.plist)
bash scripts/build.sh  # release .app bundle in .build/Murmur.app
```

To keep macOS permission grants across rebuilds, run the one-time setup so the app is signed with a stable local identity instead of ad-hoc:

```sh
bash scripts/setup-signing.sh
```

## Release (Developer ID + notarization)

Murmur can't ship on the Mac App Store — it relies on Accessibility (global hotkey, auto-paste), which Apple does not grant to sandboxed apps. Distribution is via signed + notarized DMG instead.

One-time setup (RailsSquad OU team):

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) under the RailsSquad OU team.
2. In Xcode → Settings → Accounts, sign in and create a **Developer ID Application** certificate.
3. Generate an [app-specific password](https://account.apple.com/account/manage) for your Apple ID.
4. Store notarytool credentials in the keychain:

   ```sh
   xcrun notarytool store-credentials MurmurNotary \
       --apple-id "you@example.com" \
       --team-id "YOURTEAMID" \
       --password "app-specific-password"
   ```

Then for each release:

```sh
export MURMUR_TEAM_ID=YOURTEAMID
export MURMUR_NOTARY_PROFILE=MurmurNotary
export MURMUR_VERSION=1.0.0
export MURMUR_BUILD=1
bash scripts/release.sh
```

Output: `dist/Murmur.app` and `dist/Murmur-1.0.0.dmg`, both signed, notarized, and stapled. Ship the DMG.

## License

MIT — see [LICENSE](LICENSE).
