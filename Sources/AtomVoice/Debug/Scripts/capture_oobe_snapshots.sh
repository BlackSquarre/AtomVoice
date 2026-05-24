#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP_PATH="$ROOT_DIR/dist/Test/AtomVoice.app"
OUTPUT_DIR="/tmp/atomvoice-oobe-snapshots-$(date +%Y%m%d-%H%M%S)"
BUILD_APP=1
LANGUAGES=(en zh-Hans zh-Hant ja ko es fr de)
STEPS=(0 1 2 3 4)
BUNDLE_ID="com.blacksquarre.AtomVoice"

usage() {
  printf 'Usage: %s [--app PATH] [--output DIR] [--no-build] [--languages "en de"] [--steps "2 3"]\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      BUILD_APP=0
      shift 2
      ;;
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --no-build)
      BUILD_APP=0
      shift
      ;;
    --languages)
      read -r -a LANGUAGES <<< "$2"
      shift 2
      ;;
    --steps)
      read -r -a STEPS <<< "$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$BUILD_APP" == "1" ]]; then
  (cd "$ROOT_DIR" && make dev)
fi

if [[ ! -x "$APP_PATH/Contents/MacOS/AtomVoice" ]]; then
  printf 'AtomVoice executable not found: %s\n' "$APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
printf 'Saving OOBE snapshots to %s\n' "$OUTPUT_DIR"

cleanup() {
  pkill -x AtomVoice >/dev/null 2>&1 || true
  defaults delete "$BUNDLE_ID" AppleLanguages >/dev/null 2>&1 || true
}
trap cleanup EXIT

for language in "${LANGUAGES[@]}"; do
  mkdir -p "$OUTPUT_DIR/$language"
  defaults write "$BUNDLE_ID" AppleLanguages -array "$language"
  defaults delete "$BUNDLE_ID" hasCompletedOOBE >/dev/null 2>&1 || true

  for step in "${STEPS[@]}"; do
    pkill -x AtomVoice >/dev/null 2>&1 || true
    sleep 0.4

    open -n -a "$APP_PATH" --args --debug-oobe-snapshot-step "$step"
    sleep 1.4

    screencapture -x "$OUTPUT_DIR/$language/step-$step.png"
    printf '%s step %s -> %s\n' "$language" "$step" "$OUTPUT_DIR/$language/step-$step.png"

    pkill -x AtomVoice >/dev/null 2>&1 || true
  done
done

printf 'Done. Review snapshots under %s\n' "$OUTPUT_DIR"
