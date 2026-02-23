# Signed Distribution Plan (Prepared, Not Active)

This plan is intentionally documentation-only so current workflows remain fully functional without Apple credentials.

## Current State

- Internal updates work without Apple signing:
  - `scripts/internal-update.sh`
  - `scripts/package-app.sh` (ad-hoc signed only)
- Release distribution uses GitHub archives + SHA-256.

## Future Prerequisites

When we decide to activate public signed distribution:

1. Apple Developer Program team access.
2. `Developer ID Application` certificate.
3. `Developer ID Installer` certificate (for privileged driver/component installer `.pkg`).
4. Notarization credentials (`notarytool` with App Store Connect API key or Apple ID flow).
5. Sparkle Ed25519 keypair (`SUPublicEDKey` + private key for appcast signing).

## Activation Checklist (Future)

1. Add notarized app packaging script.
- Candidate: `scripts/sign-and-notarize.sh`
- Inputs: app bundle from `scripts/package-app.sh`

2. Add signed installer package for privileged components.
- Candidate: `scripts/package-components-pkg.sh`
- Uses `pkgbuild` / `productbuild` and `Developer ID Installer`.

3. Add Sparkle feed generation + signature verification.
- Candidate: `scripts/make-appcast.sh`, `scripts/verify-appcast.sh`

4. Add GitHub Actions release workflow for signed assets.
- Validate -> package -> sign -> notarize -> staple -> publish -> verify.

## Guardrail

All future signed/notarized scripts should fail fast with explicit credential checks and must not break the existing unsigned internal flow.
