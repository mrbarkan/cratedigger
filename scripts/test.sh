#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${ROOT_DIR}/.build/tests"
DEFAULT_XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

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

explain_tooling_failure() {
  local output="$1"

  if [[ "${output}" == *"license agreements"* ]]; then
    echo "error: Xcode is installed but the Apple developer tools license has not been accepted." >&2
    echo "Run 'sudo xcodebuild -license' once, then rerun scripts/test.sh." >&2
    return
  fi

  if [[ "${output}" == *"unable to lookup item 'PlatformPath'"* ]]; then
    echo "error: XCTest execution requires a full Xcode developer directory, not Command Line Tools alone." >&2
    echo "Set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer or run 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'." >&2
    return
  fi
}

prepare_swift_environment

TEST_OUTPUT="$(
  swift test \
    --enable-xctest \
    --disable-swift-testing \
    --build-path "${BUILD_PATH}" \
    "$@" 2>&1
)" || {
  printf '%s\n' "${TEST_OUTPUT}" >&2
  explain_tooling_failure "${TEST_OUTPUT}"
  exit 1
}

printf '%s\n' "${TEST_OUTPUT}"
