# Artifact Repository

This repository stores synchronized build artifacts from:

- source repo: $SourceRoot
- source remote: $sourceRemote

Synchronized scope:

- `app-controller/app/build/outputs/apk/**/*.apk`
- `esp32-s3-supermini-rgb-control/build/esp32.esp32.esp32s3/*.ino.bin`
- `esp8266-esp01s-rgb-control/build/esp8266.esp8266.generic/*.ino.bin`
- `pilotlight-idf/build/pilotlight_esp32.bin`

The synchronized files are stored under `payload/`, preserving their relative paths from the source repository.

Recommended public update entry:

- `latest.json`
- `sources.recommendedManifestUrl` inside `latest.json`

Sync entry points:

- `sync-artifacts-and-push.ps1`
- `sync-artifacts-to-repo.ps1`
