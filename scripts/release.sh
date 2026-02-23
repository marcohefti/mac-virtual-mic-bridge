#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/version.env"
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"

source "$VERSION_FILE"

if [[ -z "${MARKETING_VERSION:-}" || -z "${BUILD_NUMBER:-}" ]]; then
  echo "version.env must define MARKETING_VERSION and BUILD_NUMBER" >&2
  exit 1
fi

DRY_RUN=0
PUBLISH=0
OUTPUT_DIR="$ROOT_DIR/dist"
ARTIFACT_PREFIX="MicBridge"
SKIP_VALIDATE=0

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh [options]

Release flow:
1) Validate repository.
2) Package release archive.
3) Create GitHub release + upload artifacts (unless --dry-run).

Options:
  --dry-run              Build and package only; do not create tag/release.
  --publish              Create a published release (default creates draft).
  --skip-validate        Skip ./scripts/validate.sh.
  --output-dir <dir>     Artifact output directory (default: ./dist).
  --artifact-prefix <n>  Archive prefix (default: MicBridge).
  --help                 Show help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    --skip-validate)
      SKIP_VALIDATE=1
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --artifact-prefix)
      ARTIFACT_PREFIX="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$CHANGELOG_FILE" ]]; then
  echo "Missing changelog file: $CHANGELOG_FILE" >&2
  exit 1
fi

ensure_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit/stash changes before release." >&2
    exit 1
  fi
}

ensure_changelog_version_ready() {
  local first_heading
  first_heading="$(awk '/^## /{print $2; exit}' "$CHANGELOG_FILE")"
  if [[ "$first_heading" != "$MARKETING_VERSION" ]]; then
    echo "Top changelog entry must match MARKETING_VERSION=$MARKETING_VERSION (found: ${first_heading:-none})" >&2
    exit 1
  fi
}

extract_release_notes() {
  local notes_file="$1"
  awk -v version="$MARKETING_VERSION" '
    $0 ~ "^## " version "$" { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$CHANGELOG_FILE" > "$notes_file"

  if [[ ! -s "$notes_file" ]]; then
    echo "Could not extract release notes for version $MARKETING_VERSION from $CHANGELOG_FILE" >&2
    exit 1
  fi
}

TAG="v${MARKETING_VERSION}"
ARCHIVE_NAME="${ARTIFACT_PREFIX}-${MARKETING_VERSION}-macos.tar.gz"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
SHA_PATH="${ARCHIVE_PATH}.sha256"
APP_ZIP_NAME="MicBridge-${MARKETING_VERSION}.zip"
APP_ZIP_PATH="$OUTPUT_DIR/$APP_ZIP_NAME"
APP_ZIP_SHA_PATH="${APP_ZIP_PATH}.sha256"

cd "$ROOT_DIR"

if [[ "$DRY_RUN" -eq 0 ]]; then
  ensure_clean_worktree
fi

ensure_changelog_version_ready

if [[ "$SKIP_VALIDATE" -eq 0 ]]; then
  ./scripts/validate.sh
fi

./scripts/package-release.sh --output-dir "$OUTPUT_DIR" --artifact-prefix "$ARTIFACT_PREFIX"
./scripts/package-cask-assets.sh --output-dir "$OUTPUT_DIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[release] Dry run complete."
  echo "[release] Artifacts:"
  echo "  $ARCHIVE_PATH"
  echo "  $SHA_PATH"
  echo "  $APP_ZIP_PATH"
  echo "  $APP_ZIP_SHA_PATH"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required for release publishing." >&2
  exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release/tag already exists: $TAG" >&2
  exit 1
fi

NOTES_FILE="$(mktemp -t micbridge-release-notes.XXXXXX.md)"
cleanup() {
  rm -f "$NOTES_FILE"
}
trap cleanup EXIT

extract_release_notes "$NOTES_FILE"

DRAFT_FLAG=(--draft)
if [[ "$PUBLISH" -eq 1 ]]; then
  DRAFT_FLAG=()
fi

gh release create "$TAG" \
  "$ARCHIVE_PATH" \
  "$SHA_PATH" \
  "$APP_ZIP_PATH" \
  "$APP_ZIP_SHA_PATH" \
  --title "MicBridge ${MARKETING_VERSION}" \
  --notes-file "$NOTES_FILE" \
  "${DRAFT_FLAG[@]}"

./scripts/check-release-assets.sh "$TAG" "$ARTIFACT_PREFIX"

echo "[release] Created release $TAG"
