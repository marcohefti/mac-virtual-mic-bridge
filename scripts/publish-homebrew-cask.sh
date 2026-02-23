#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/version.env"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing version file: $VERSION_FILE" >&2
  exit 1
fi
source "$VERSION_FILE"

if [[ -z "${MARKETING_VERSION:-}" ]]; then
  echo "version.env must define MARKETING_VERSION" >&2
  exit 1
fi

TAP_REPO="marcohefti/homebrew-micbridge"
CASK_TOKEN="micbridge"
APP_NAME="MicBridge"
RELEASE_TAG="v${MARKETING_VERSION}"
CREATE_REPO=1
PUBLIC_REPO=1
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/publish-homebrew-cask.sh [options]

Publish/update a private tap cask that points to this repo's GitHub release app zip.

Options:
  --tap-repo <owner/name>   Tap repository slug (default: marcohefti/homebrew-micbridge)
  --cask-token <token>      Cask token/filename (default: micbridge)
  --app-name <name>         App bundle/display name (default: MicBridge)
  --release-tag <tag>       Release tag to reference (default: v<MARKETING_VERSION>)
  --no-create-repo          Do not create tap repo when missing.
  --private-repo            Create tap repo as private if created.
  --dry-run                 Print cask file and skip git push.
  --help                    Show help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-repo)
      TAP_REPO="$2"
      shift 2
      ;;
    --cask-token)
      CASK_TOKEN="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --release-tag)
      RELEASE_TAG="$2"
      shift 2
      ;;
    --no-create-repo)
      CREATE_REPO=0
      shift
      ;;
    --private-repo)
      PUBLIC_REPO=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi

origin_url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
if [[ -z "$origin_url" ]]; then
  echo "Could not resolve git origin URL from this repo" >&2
  exit 1
fi

case "$origin_url" in
  git@github.com:*)
    APP_REPO="${origin_url#git@github.com:}"
    ;;
  https://github.com/*)
    APP_REPO="${origin_url#https://github.com/}"
    ;;
  http://github.com/*)
    APP_REPO="${origin_url#http://github.com/}"
    ;;
  *)
    echo "Unsupported origin URL format: $origin_url" >&2
    exit 1
    ;;
esac
APP_REPO="${APP_REPO%.git}"

APP_ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
APP_ZIP_SHA_NAME="${APP_ZIP_NAME}.sha256"

ASSET_NAMES="$(gh release view "$RELEASE_TAG" --repo "$APP_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)"
if [[ -z "$ASSET_NAMES" ]]; then
  echo "No release assets found for $APP_REPO tag $RELEASE_TAG" >&2
  exit 1
fi

if ! echo "$ASSET_NAMES" | grep -Fx "$APP_ZIP_NAME" >/dev/null; then
  echo "Release missing app zip asset: $APP_ZIP_NAME" >&2
  exit 1
fi
if ! echo "$ASSET_NAMES" | grep -Fx "$APP_ZIP_SHA_NAME" >/dev/null; then
  echo "Release missing app zip checksum asset: $APP_ZIP_SHA_NAME" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d -t micbridge-tap.XXXXXX)"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if ! gh repo view "$TAP_REPO" >/dev/null 2>&1; then
  if [[ "$CREATE_REPO" -eq 0 ]]; then
    echo "Tap repo does not exist and --no-create-repo was set: $TAP_REPO" >&2
    exit 1
  fi

  visibility_flag="--public"
  if [[ "$PUBLIC_REPO" -eq 0 ]]; then
    visibility_flag="--private"
  fi

  gh repo create "$TAP_REPO" "$visibility_flag" --description "Homebrew tap for MicBridge" --confirm
fi

gh release download "$RELEASE_TAG" \
  --repo "$APP_REPO" \
  --pattern "$APP_ZIP_SHA_NAME" \
  --dir "$TMP_ROOT" >/dev/null

if [[ ! -f "$TMP_ROOT/$APP_ZIP_SHA_NAME" ]]; then
  echo "Failed to download $APP_ZIP_SHA_NAME" >&2
  exit 1
fi

APP_SHA="$(awk '{print $1}' "$TMP_ROOT/$APP_ZIP_SHA_NAME")"
if [[ -z "$APP_SHA" ]]; then
  echo "Could not parse SHA from $APP_ZIP_SHA_NAME" >&2
  exit 1
fi

gh repo clone "$TAP_REPO" "$TMP_ROOT/tap" -- --depth 1 >/dev/null
TAP_DIR="$TMP_ROOT/tap"

mkdir -p "$TAP_DIR/Casks"
CASK_PATH="$TAP_DIR/Casks/${CASK_TOKEN}.rb"

cat > "$CASK_PATH" <<RUBY
cask "${CASK_TOKEN}" do
  version "${MARKETING_VERSION}"
  sha256 "${APP_SHA}"

  url "https://github.com/${APP_REPO}/releases/download/${RELEASE_TAG}/${APP_ZIP_NAME}"
  name "${APP_NAME}"
  desc "Resilient macOS virtual microphone bridge"
  homepage "https://github.com/${APP_REPO}"

  depends_on macos: ">= :sonoma"
  app "${APP_NAME}.app"

  caveats do
    <<~EOS
      This is distributed via a private tap and may be unsigned.
      If macOS blocks first launch, open ${APP_NAME} once via Finder and allow it in
      System Settings > Privacy & Security.
    EOS
  end

  zap trash: [
    "~/Library/Application Support/MacVirtualMicBridge",
    "~/Library/Logs/MacVirtualMicBridge",
    "~/Library/LaunchAgents/ch.hefti.macvirtualmicbridge.daemon.plist",
    "~/Library/LaunchAgents/ch.hefti.macvirtualmicbridge.menubar.plist"
  ]
end
RUBY

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[publish-homebrew-cask] Dry run cask file:"
  cat "$CASK_PATH"
  exit 0
fi

cd "$TAP_DIR"
git add "$CASK_PATH"

if git diff --cached --quiet; then
  echo "Tap cask already up to date: $TAP_REPO/Casks/${CASK_TOKEN}.rb"
  exit 0
fi

git commit -m "cask(${CASK_TOKEN}): ${MARKETING_VERSION}"
git push

echo "Published cask: https://github.com/$TAP_REPO/blob/main/Casks/${CASK_TOKEN}.rb"
echo "Install with:"
echo "  brew tap ${TAP_REPO}"
echo "  brew install --cask ${TAP_REPO}/${CASK_TOKEN}"
