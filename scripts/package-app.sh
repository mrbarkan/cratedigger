#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${ROOT_DIR}/.build/package-app"
OUTPUT_DIR="${ROOT_DIR}/dist"
APP_NAME="CrateDigger.app"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}"
INFO_PLIST_SOURCE="${ROOT_DIR}/Packaging/CrateDiggerApp/Info.plist"
ICON_SOURCE="${ROOT_DIR}/Packaging/CrateDiggerApp/Resources/CrateDigger.icns"
DEFAULT_XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

FFMPEG_PATH="${CRATEDIGGER_FFMPEG_PATH:-}"
FFPROBE_PATH="${CRATEDIGGER_FFPROBE_PATH:-}"

usage() {
  cat <<'EOF'
Usage: scripts/package-app.sh [--ffmpeg PATH] [--ffprobe PATH] [--output PATH]

Builds a release executable with SwiftPM, assembles CrateDigger.app, bundles
ffmpeg and ffprobe into Contents/Resources, and ad-hoc signs the resulting app.
EOF
}

resolve_developer_dir() {
  if [[ -n "${CRATEDIGGER_DEVELOPER_DIR:-}" ]]; then
    printf '%s\n' "${CRATEDIGGER_DEVELOPER_DIR}"
    return
  fi

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    printf '%s\n' "${DEVELOPER_DIR}"
    return
  fi

  if [[ -d "${DEFAULT_XCODE_DEVELOPER_DIR}" ]]; then
    printf '%s\n' "${DEFAULT_XCODE_DEVELOPER_DIR}"
    return
  fi

  xcode-select -p 2>/dev/null || true
}

prepare_swift_environment() {
  local developer_dir
  developer_dir="$(resolve_developer_dir)"
  if [[ -n "${developer_dir}" ]]; then
    export DEVELOPER_DIR="${developer_dir}"
  fi

  mkdir -p "${BUILD_PATH}/module-cache"
  export CLANG_MODULE_CACHE_PATH="${BUILD_PATH}/module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_PATH}/module-cache"
}

explain_build_failure() {
  local output="$1"

  if [[ "${output}" == *"license agreements"* ]]; then
    echo "error: Xcode is installed but the Apple developer tools license has not been accepted." >&2
    echo "Run 'sudo xcodebuild -license' once, then rerun scripts/package-app.sh." >&2
    return
  fi

  if [[ "${output}" == *"unable to lookup item 'PlatformPath'"* ]]; then
    echo "error: Full Xcode is recommended for packaging and codesigning the app bundle." >&2
    echo "Set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer or run 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'." >&2
    return
  fi
}

resolve_tool() {
  local explicit_path="$1"
  local executable_name="$2"

  if [[ -n "${explicit_path}" ]]; then
    if [[ ! -x "${explicit_path}" ]]; then
      echo "error: ${executable_name} not executable at ${explicit_path}" >&2
      exit 1
    fi
    printf '%s\n' "${explicit_path}"
    return
  fi

  local resolved
  resolved="$(command -v "${executable_name}" || true)"
  if [[ -z "${resolved}" ]]; then
    echo "error: could not find ${executable_name}. Pass --${executable_name} PATH or set CRATEDIGGER_${executable_name^^}_PATH." >&2
    exit 1
  fi

  printf '%s\n' "${resolved}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ffmpeg)
      FFMPEG_PATH="${2:?missing path for --ffmpeg}"
      shift 2
      ;;
    --ffprobe)
      FFPROBE_PATH="${2:?missing path for --ffprobe}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:?missing path for --output}"
      APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${INFO_PLIST_SOURCE}" ]]; then
  echo "error: missing Info.plist template at ${INFO_PLIST_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "error: missing app icon at ${ICON_SOURCE}" >&2
  echo "Run 'swift scripts/generate-brand-assets.swift' to generate the design package assets." >&2
  exit 1
fi

FFMPEG_PATH="$(resolve_tool "${FFMPEG_PATH}" "ffmpeg")"
FFPROBE_PATH="$(resolve_tool "${FFPROBE_PATH}" "ffprobe")"
prepare_swift_environment

mkdir -p "${OUTPUT_DIR}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

BUILD_OUTPUT="$(
  swift build \
    --configuration release \
    --product CrateDiggerApp \
    --build-path "${BUILD_PATH}" 2>&1
)" || {
  printf '%s\n' "${BUILD_OUTPUT}" >&2
  explain_build_failure "${BUILD_OUTPUT}"
  exit 1
}

printf '%s\n' "${BUILD_OUTPUT}"

BINARY_PATH="$(find "${BUILD_PATH}" -type f -path '*/release/CrateDiggerApp' | head -n 1)"
if [[ -z "${BINARY_PATH}" ]]; then
  echo "error: could not locate release CrateDiggerApp binary in ${BUILD_PATH}" >&2
  exit 1
fi

cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/CrateDiggerApp"
cp "${INFO_PLIST_SOURCE}" "${APP_BUNDLE}/Contents/Info.plist"
cp "${ICON_SOURCE}" "${APP_BUNDLE}/Contents/Resources/CrateDigger.icns"
cp "${FFMPEG_PATH}" "${APP_BUNDLE}/Contents/Resources/ffmpeg"
cp "${FFPROBE_PATH}" "${APP_BUNDLE}/Contents/Resources/ffprobe"

chmod 755 "${APP_BUNDLE}/Contents/MacOS/CrateDiggerApp"
chmod 755 "${APP_BUNDLE}/Contents/Resources/ffmpeg" "${APP_BUNDLE}/Contents/Resources/ffprobe"

codesign --force --sign - --timestamp=none "${APP_BUNDLE}/Contents/Resources/ffmpeg"
codesign --force --sign - --timestamp=none "${APP_BUNDLE}/Contents/Resources/ffprobe"
codesign --force --deep --sign - --timestamp=none "${APP_BUNDLE}"

echo "Packaged ${APP_BUNDLE}"
