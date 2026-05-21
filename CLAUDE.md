# Murmur

Menu-bar push-to-talk dictation: record mic audio, transcribe via Groq Whisper, paste the text.

## Build & run

- `scripts/build.sh` — debug-grade signed `.build/Murmur.app` for local testing.
- `scripts/run.sh` — build and launch.
- `swift build` — compile only.

## Releasing (notarized DMG + GitHub release)

The signing/notarization identity belongs to the **RailsSquad OU** developer account, not the
primary gmail.

| Setting              | Value                                      |
|----------------------|--------------------------------------------|
| Team ID              | `VLZY44ZX2X`                               |
| Apple ID (notary)    | `guillaume.voisin29+railssquad@gmail.com`  |
| Signing identity     | `Developer ID Application: RailsSquad OU (VLZY44ZX2X)` |
| notarytool profile   | `Murmur`                                   |
| App-specific password| `NOTARIZATION_PASSWORD` in `.env` (gitignored) |

### One-time notary credential setup

The keychain profile `Murmur` may not exist on a fresh machine. Recreate it from `.env`:

```bash
set -a; source .env; set +a
xcrun notarytool store-credentials "Murmur" \
  --apple-id "guillaume.voisin29+railssquad@gmail.com" \
  --team-id "VLZY44ZX2X" \
  --password "$NOTARIZATION_PASSWORD"
```

### Cut a release

```bash
export MURMUR_TEAM_ID="VLZY44ZX2X" MURMUR_NOTARY_PROFILE="Murmur"
export MURMUR_VERSION="1.0.x" MURMUR_BUILD="N"   # bump both together
./scripts/release.sh                              # builds, signs, notarizes, staples → dist/Murmur-<v>.dmg

gh release create v1.0.x dist/Murmur-1.0.x.dmg --title "Murmur 1.0.x" --notes "..."
```

`release.sh` produces a universal (arm64 + x86_64), hardened-runtime, notarized & stapled DMG so it
opens with a plain double-click — no Gatekeeper warning.

## Conventions

- Stage files by name; never `git add -A`.
- Bump `MURMUR_VERSION` and `MURMUR_BUILD` together.
- Never commit `.env`.
