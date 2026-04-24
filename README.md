# Murmur

A lightweight macOS menu bar app that turns your voice into text wherever your cursor is. Hold right-Option, talk, release — the transcription is pasted automatically.

Powered by [Groq](https://console.groq.com) + Whisper.

## Requirements

- macOS 13 (Ventura) or later
- A free [Groq API key](https://console.groq.com)
- Xcode command-line tools (`xcode-select --install`)

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

## License

MIT — see [LICENSE](LICENSE).
