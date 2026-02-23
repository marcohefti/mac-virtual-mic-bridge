# Releasing Runbook

This runbook documents the baseline release flow for MicBridge.

## Prerequisites

- `version.env` updated (`MARKETING_VERSION`, `BUILD_NUMBER`)
- `CHANGELOG.md` top section finalized for `MARKETING_VERSION`
- `gh` authenticated to the target GitHub repository

## Dry-run packaging

Build and package without creating a release:

```bash
./scripts/release.sh --dry-run
```

Outputs:
- `dist/MicBridge-<version>-macos.tar.gz`
- `dist/MicBridge-<version>-macos.tar.gz.sha256`

Optional internal `.app` packaging (ad-hoc signed, non-notarized):

```bash
./scripts/package-app.sh
```

## Draft release

Create a draft GitHub release with packaged assets:

```bash
./scripts/release.sh
```

## Published release

Create and publish immediately:

```bash
./scripts/release.sh --publish
```

## Post-release verification

```bash
./scripts/check-release-assets.sh v<version>
./scripts/validate-internal-update.sh
```

This verifies that the archive and checksum assets are attached to the release.
