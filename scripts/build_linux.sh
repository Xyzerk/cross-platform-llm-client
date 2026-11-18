#!/usr/bin/env bash
#
# Build PrivateLM for Linux.
#
#   scripts/build_linux.sh                 # debug bundle
#   scripts/build_linux.sh --release       # release bundle
#   scripts/build_linux.sh --release --vulkan
#   scripts/build_linux.sh --release --package
#
# Prerequisites are documented in docs/linux-build.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="debug"
VULKAN=0
SKIP_PUB_GET=0
PACKAGE=0

usage() {
  cat <<'EOF'
Usage: scripts/build_linux.sh [options]

  -d, --debug        Build the debug bundle (default)
  -p, --profile      Build the profile bundle
  -r, --release      Build the release bundle
      --vulkan       Compile llama.cpp's Vulkan backend (needs the Vulkan SDK)
      --skip-pub-get Skip `flutter pub get`
      --package      Write build/linux/privatelm-<version>-linux-x64.tar.gz
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--debug) MODE="debug" ;;
    -p|--profile) MODE="profile" ;;
    -r|--release) MODE="release" ;;
    --vulkan) VULKAN=1 ;;
    --skip-pub-get) SKIP_PUB_GET=1 ;;
    --package) PACKAGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

find_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return
  fi

  local candidate
  if [[ -f "$ROOT/android/local.properties" ]]; then
    candidate="$(sed -n 's/^flutter\.sdk=//p' "$ROOT/android/local.properties" | head -n1)"
    if [[ -n "${candidate:-}" && -x "$candidate/bin/flutter" ]]; then
      echo "$candidate/bin/flutter"
      return
    fi
  fi

  for candidate in \
    "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    "/opt/flutter/bin/flutter" \
    "/usr/local/flutter/bin/flutter"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "Flutter SDK not found. Install Flutter and put it on PATH, or set" >&2
  echo "flutter.sdk in android/local.properties." >&2
  exit 1
}

check_native_deps() {
  local missing=0
  for tool in cmake ninja clang++ pkg-config; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing build tool: $tool" >&2
      missing=1
    fi
  done
  for module in gtk+-3.0 glib-2.0 gio-2.0; do
    if ! pkg-config --exists "$module"; then
      echo "Missing development package: $module" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "See docs/linux-build.md for the package list." >&2
    exit 1
  fi
}

FLUTTER="$(find_flutter)"
check_native_deps

if [[ "$VULKAN" -eq 1 ]]; then
  export PRIVATELM_LINUX_VULKAN=1
fi

if [[ "$SKIP_PUB_GET" -eq 0 ]]; then
  echo "==> flutter pub get"
  "$FLUTTER" pub get
fi

echo "==> flutter build linux --$MODE"
"$FLUTTER" build linux "--$MODE"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
esac

BUNDLE="$ROOT/build/linux/$ARCH/$MODE/bundle"
if [[ ! -x "$BUNDLE/privatelm" ]]; then
  echo "Build output not found: $BUNDLE/privatelm" >&2
  exit 1
fi
if [[ ! -f "$BUNDLE/lib/libllama_flutter_android.so" ]]; then
  echo "Plugin library missing from the bundle: lib/libllama_flutter_android.so" >&2
  echo "Check the llama.cpp build output above." >&2
  exit 1
fi
if [[ ! -x "$BUNDLE/lib/privatelm_rpc_worker" ]]; then
  echo "Cluster worker missing from the bundle: lib/privatelm_rpc_worker" >&2
  echo "Check the llama.cpp build output above." >&2
  exit 1
fi

echo "==> Built $BUNDLE"
echo "    Run: $BUNDLE/privatelm"

if [[ "$PACKAGE" -eq 1 ]]; then
  VERSION="$(sed -n 's/^version: *//p' "$ROOT/pubspec.yaml" | head -n1)"
  VERSION="${VERSION/+/-}"
  OUT="$ROOT/build/linux/privatelm-${VERSION:-dev}-linux-$ARCH.tar.gz"
  mkdir -p "$ROOT/build/linux"
  tar -C "$BUNDLE" -czf "$OUT" .
  echo "==> Packaged $OUT"
fi
