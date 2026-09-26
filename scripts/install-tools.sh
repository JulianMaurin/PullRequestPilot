#!/bin/bash
# Installs pinned, checksum-verified releases of the tools CI runs into
# .build/tools (or $TOOLS_DIR) and prints the bin directory, so a workflow can
# append it to $GITHUB_PATH.
#
# Usage: scripts/install-tools.sh <swiftlint|xcodegen|gitleaks|actionlint>...
#
# Supports the CI runners: macOS arm64 and Linux x86_64. Bump a version and
# its checksums together; each checksum is the release asset's SHA-256 digest.

set -euo pipefail

SWIFTLINT_VERSION=0.65.0
SWIFTLINT_SHA256_DARWIN=d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6
SWIFTLINT_SHA256_LINUX=79306a34e5c7cc55a220cd108cbb861dcad5f10138dcdf261e2624ae8b0a486b

XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256_DARWIN=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256_DARWIN=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
GITLEAKS_SHA256_LINUX=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256_DARWIN=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
ACTIONLINT_SHA256_LINUX=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/.build/tools}"
BIN_DIR="$TOOLS_DIR/bin"
DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM=darwin ;;
  Linux-x86_64) PLATFORM=linux ;;
  *) echo "install-tools: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# $1 = URL, $2 = expected SHA-256; prints the path of the verified download.
download() {
  local url="$1" expected="$2" file actual
  file="$DOWNLOAD_DIR/$(basename "$url")"
  curl --fail --silent --show-error --location --retry 3 --output "$file" "$url"
  actual=$(sha256 "$file")
  if [[ "$actual" != "$expected" ]]; then
    echo "install-tools: checksum mismatch for $url (expected $expected, got $actual)" >&2
    exit 1
  fi
  echo "$file"
}

install_swiftlint() {
  local asset expected archive
  if [[ "$PLATFORM" == darwin ]]; then
    asset=portable_swiftlint.zip expected=$SWIFTLINT_SHA256_DARWIN
  else
    asset=swiftlint_linux_amd64.zip expected=$SWIFTLINT_SHA256_LINUX
  fi
  archive=$(download "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/$asset" "$expected")
  unzip -q -o "$archive" swiftlint -d "$BIN_DIR"
}

# XcodeGen looks for its setting presets in ../share/xcodegen next to the path
# it was invoked by, symlinks unresolved; without them it silently generates a
# project missing the preset settings (TEST_HOST among them).
install_xcodegen() {
  local archive
  if [[ "$PLATFORM" != darwin ]]; then
    echo "install-tools: xcodegen is only needed on macOS" >&2
    exit 1
  fi
  archive=$(download "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" "$XCODEGEN_SHA256_DARWIN")
  unzip -q -o "$archive" -d "$DOWNLOAD_DIR"
  rm -rf "$TOOLS_DIR/share/xcodegen"
  mkdir -p "$TOOLS_DIR/share"
  mv "$DOWNLOAD_DIR/xcodegen/share/xcodegen" "$TOOLS_DIR/share/xcodegen"
  mv "$DOWNLOAD_DIR/xcodegen/bin/xcodegen" "$BIN_DIR/xcodegen"
}

install_gitleaks() {
  local asset expected archive
  if [[ "$PLATFORM" == darwin ]]; then
    asset=gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz expected=$GITLEAKS_SHA256_DARWIN
  else
    asset=gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz expected=$GITLEAKS_SHA256_LINUX
  fi
  archive=$(download "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/$asset" "$expected")
  tar -xzf "$archive" -C "$BIN_DIR" gitleaks
}

install_actionlint() {
  local asset expected archive
  if [[ "$PLATFORM" == darwin ]]; then
    asset=actionlint_${ACTIONLINT_VERSION}_darwin_arm64.tar.gz expected=$ACTIONLINT_SHA256_DARWIN
  else
    asset=actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz expected=$ACTIONLINT_SHA256_LINUX
  fi
  archive=$(download "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/$asset" "$expected")
  tar -xzf "$archive" -C "$BIN_DIR" actionlint
}

if (( $# == 0 )); then
  echo "usage: scripts/install-tools.sh <swiftlint|xcodegen|gitleaks|actionlint>..." >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
for tool in "$@"; do
  case "$tool" in
    swiftlint)  install_swiftlint ;;
    xcodegen)   install_xcodegen ;;
    gitleaks)   install_gitleaks ;;
    actionlint) install_actionlint ;;
    *) echo "install-tools: unknown tool $tool" >&2; exit 1 ;;
  esac
done
echo "$BIN_DIR"
