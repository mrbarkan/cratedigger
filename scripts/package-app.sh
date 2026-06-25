#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${ROOT_DIR}/.build/package-app"
OUTPUT_DIR="${ROOT_DIR}/dist"
APP_NAME="CrateDigger.app"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}"
INFO_PLIST_SOURCE="${ROOT_DIR}/Packaging/CrateDiggerApp/Info.plist"
ENTITLEMENTS_SOURCE="${ROOT_DIR}/Packaging/CrateDiggerApp/CrateDigger.entitlements"
ICON_SOURCE="${ROOT_DIR}/Packaging/CrateDiggerApp/Resources/CrateDigger.icns"
DEFAULT_XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

FFMPEG_PATH="${CRATEDIGGER_FFMPEG_PATH:-}"
FFPROBE_PATH="${CRATEDIGGER_FFPROBE_PATH:-}"
SIGN_IDENTITY="${CRATEDIGGER_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${CRATEDIGGER_NOTARY_PROFILE:-}"
MAKE_DMG=0
DO_NOTARIZE=0

usage() {
  cat <<'EOF'
Usage: scripts/package-app.sh [options]

Builds a release executable with SwiftPM, assembles CrateDigger.app, bundles
ffmpeg and ffprobe into Contents/Resources, and signs the resulting app.

Options:
  --ffmpeg PATH            Path to ffmpeg binary (or CRATEDIGGER_FFMPEG_PATH)
  --ffprobe PATH           Path to ffprobe (or CRATEDIGGER_FFPROBE_PATH)
  --output PATH            Output directory (default: ./dist)
  --sign IDENTITY          Developer ID signing identity, e.g.
                           "Developer ID Application: Acme Inc (TEAMID)".
                           Without this, the bundle is ad-hoc signed.
                           Env: CRATEDIGGER_SIGNING_IDENTITY
  --notarize               Submit the resulting bundle (and DMG, if --dmg)
                           to Apple's notary service and staple. Requires
                           --sign and a keychain profile.
                           Env: CRATEDIGGER_NOTARY_PROFILE (the profile name
                           you stored via 'xcrun notarytool store-credentials').
  --dmg                    After packaging, produce dist/CrateDigger-<version>.dmg
                           via hdiutil. Signed and notarized when those
                           options are also set.
  --help, -h               Show this help

Distribution build example:
  CRATEDIGGER_NOTARY_PROFILE=cratedigger-notary \
    scripts/package-app.sh \
      --sign "Developer ID Application: Your Name (TEAMID)" \
      --notarize \
      --dmg
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

read_app_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST_SOURCE}" 2>/dev/null || echo "0.0.0"
}

sign_distribution() {
  local target="$1"
  local needs_entitlements="${2:-no}"

  if [[ "${needs_entitlements}" == "yes" ]]; then
    codesign --force \
      --options runtime \
      --timestamp \
      --entitlements "${ENTITLEMENTS_SOURCE}" \
      --sign "${SIGN_IDENTITY}" \
      "${target}"
  else
    codesign --force \
      --options runtime \
      --timestamp \
      --sign "${SIGN_IDENTITY}" \
      "${target}"
  fi
}

sign_adhoc() {
  local target="$1"
  codesign --force --sign - --timestamp=none "${target}"
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
    --sign)
      SIGN_IDENTITY="${2:?missing identity for --sign}"
      shift 2
      ;;
    --notarize)
      DO_NOTARIZE=1
      shift 1
      ;;
    --dmg)
      MAKE_DMG=1
      shift 1
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

if [[ "${DO_NOTARIZE}" -eq 1 && -z "${SIGN_IDENTITY}" ]]; then
  echo "error: --notarize requires --sign IDENTITY (Developer ID is required to notarize)." >&2
  exit 1
fi

if [[ "${DO_NOTARIZE}" -eq 1 && -z "${NOTARY_PROFILE}" ]]; then
  echo "error: --notarize requires CRATEDIGGER_NOTARY_PROFILE to be set to a stored notarytool profile." >&2
  echo "Run once: xcrun notarytool store-credentials cratedigger-notary --apple-id <id> --team-id <team> --password <app-specific-password>" >&2
  exit 1
fi

if [[ ! -f "${INFO_PLIST_SOURCE}" ]]; then
  echo "error: missing Info.plist template at ${INFO_PLIST_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "error: missing app icon at ${ICON_SOURCE}" >&2
  echo "Run 'swift scripts/generate-brand-assets.swift' to generate the design package assets." >&2
  exit 1
fi

if [[ -n "${SIGN_IDENTITY}" && ! -f "${ENTITLEMENTS_SOURCE}" ]]; then
  echo "error: missing entitlements template at ${ENTITLEMENTS_SOURCE} (required for distribution signing)" >&2
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

if [[ -n "${SIGN_IDENTITY}" ]]; then
  echo "Signing for distribution as: ${SIGN_IDENTITY}"
  # Sign nested binaries first (inside-out), then the app bundle.
  sign_distribution "${APP_BUNDLE}/Contents/Resources/ffmpeg" "no"
  sign_distribution "${APP_BUNDLE}/Contents/Resources/ffprobe" "no"
  sign_distribution "${APP_BUNDLE}/Contents/MacOS/CrateDiggerApp" "yes"
  sign_distribution "${APP_BUNDLE}" "yes"
  codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
else
  echo "Ad-hoc signing (development build; not suitable for distribution)"
  sign_adhoc "${APP_BUNDLE}/Contents/Resources/ffmpeg"
  sign_adhoc "${APP_BUNDLE}/Contents/Resources/ffprobe"
  codesign --force --deep --sign - --timestamp=none "${APP_BUNDLE}"
fi

echo "Packaged ${APP_BUNDLE}"

if [[ "${DO_NOTARIZE}" -eq 1 ]]; then
  echo "Submitting app bundle for notarization (this may take several minutes)..."
  NOTARY_ZIP="${OUTPUT_DIR}/CrateDigger-notary.zip"
  rm -f "${NOTARY_ZIP}"
  /usr/bin/ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"
  xcrun notarytool submit "${NOTARY_ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
  rm -f "${NOTARY_ZIP}"
  xcrun stapler staple "${APP_BUNDLE}"
  xcrun stapler validate "${APP_BUNDLE}"
  spctl -a -vv "${APP_BUNDLE}" || true
  echo "Notarized and stapled ${APP_BUNDLE}"
fi

if [[ "${MAKE_DMG}" -eq 1 ]]; then
  APP_VERSION="$(read_app_version)"
  DMG_PATH="${OUTPUT_DIR}/CrateDigger-${APP_VERSION}.dmg"
  STAGE_DIR="${BUILD_PATH}/dmg-stage"
  echo "Building DMG at ${DMG_PATH}"

  rm -rf "${STAGE_DIR}"
  mkdir -p "${STAGE_DIR}"
  /usr/bin/ditto "${APP_BUNDLE}" "${STAGE_DIR}/${APP_NAME}"
  ln -s /Applications "${STAGE_DIR}/Applications"

  rm -f "${DMG_PATH}"
  hdiutil create \
    -volname "CrateDigger ${APP_VERSION}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

  rm -rf "${STAGE_DIR}"

  if [[ -n "${SIGN_IDENTITY}" ]]; then
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"
  fi

  if [[ "${DO_NOTARIZE}" -eq 1 ]]; then
    echo "Notarizing DMG..."
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    # Let Apple's ticket service propagate before stapling. Stapling the DMG
    # immediately after the submit returns can fail and truncate the image to a
    # ~672-byte stub, so wait and retry a few times.
    stapled=0
    for attempt in 1 2 3 4 5; do
      sleep 10
      if xcrun stapler staple "${DMG_PATH}"; then stapled=1; break; fi
      echo "  stapler attempt ${attempt} failed; retrying..."
    done
    if [[ "${stapled}" -ne 1 ]]; then
      echo "error: could not staple ${DMG_PATH} after ${attempt} attempts" >&2
      exit 1
    fi
    xcrun stapler validate "${DMG_PATH}"
  fi

  echo "DMG ready: ${DMG_PATH}"
fi
