#!/usr/bin/env sh
# Bangun binary server Syncfony untuk target Linux (cross-compile secara otomatis).
#
#   scripts/build-server.sh aarch64-unknown-linux-gnu
#   scripts/build-server.sh x86_64-unknown-linux-gnu
#
# Urutan pemilihan tool:
#   1. SYNCFONY_SERVER_BUILDER (cross | zigbuild | native)
#   2. cross            (butuh Docker daemon)
#   3. cargo-zigbuild   (butuh zig)
#   4. cargo native     (hanya bila host Linux se-arsitektur dengan target)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SERVER_DIR="$ROOT_DIR/server"
OUT_DIR="$ROOT_DIR/output"

TARGET=${1:-}
if [ -z "$TARGET" ]; then
  echo "pemakaian: $0 <target-triple>" >&2
  echo "contoh   : $0 aarch64-unknown-linux-gnu" >&2
  exit 2
fi

case "$TARGET" in
  aarch64-unknown-linux-gnu) SUFFIX=linux-arm64 ;;
  x86_64-unknown-linux-gnu)  SUFFIX=linux-x86_64 ;;
  *)                         SUFFIX=$TARGET ;;
esac

VERSION=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$SERVER_DIR/Cargo.toml" | head -n1)
VERSION=${VERSION:-0.1.0}

have() { command -v "$1" >/dev/null 2>&1; }

host_os() {
  case "$(uname -s)" in
    Linux)   echo linux ;;
    Darwin)  echo darwin ;;
    *)       echo other ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64)  echo x86_64 ;;
    *)             echo other ;;
  esac
}

target_arch() {
  case "$1" in
    *aarch64*) echo arm64 ;;
    *x86_64*)  echo x86_64 ;;
    *)         echo other ;;
  esac
}

pick_builder() {
  if [ -n "${SYNCFONY_SERVER_BUILDER:-}" ]; then
    echo "$SYNCFONY_SERVER_BUILDER"
    return
  fi
  if have cross; then
    echo cross
    return
  fi
  if have cargo-zigbuild && have zig; then
    echo zigbuild
    return
  fi
  if [ "$(host_os)" = linux ] && [ "$(host_arch)" = "$(target_arch "$TARGET")" ]; then
    echo native
    return
  fi
  echo none
}

BUILDER=$(pick_builder)

case "$BUILDER" in
  cross)
    if ! have docker; then
      echo "✗ cross terpasang tapi docker tidak ditemukan." >&2
      exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
      echo "✗ Docker daemon tidak berjalan (buka Docker Desktop lalu ulangi)." >&2
      exit 1
    fi
    echo "→ cross build $TARGET"
    ( cd "$SERVER_DIR" && cross build --release --target "$TARGET" )
    BIN="$SERVER_DIR/target/$TARGET/release/syncfony"
    ;;
  zigbuild)
    # zigbuild butuh versi glibc; 2.28 aman untuk Debian 10+ / Ubuntu 20.04+
    echo "→ cargo zigbuild $TARGET (glibc 2.28)"
    ( cd "$SERVER_DIR" && cargo zigbuild --release --target "$TARGET.2.28" )
    BIN="$SERVER_DIR/target/$TARGET/release/syncfony"
    ;;
  native)
    echo "→ cargo build --release $TARGET (native)"
    ( cd "$SERVER_DIR" && cargo build --release --target "$TARGET" )
    BIN="$SERVER_DIR/target/$TARGET/release/syncfony"
    ;;
  *)
    cat >&2 <<'EOF'
✗ Belum ada tool untuk cross-compile ke Linux. Pilih salah satu:

  1) cargo install cross --locked        (butuh Docker Desktop aktif)
  2) cargo install cargo-zigbuild && brew install zig
  3) jalankan build di mesin Linux tujuan: SYNCFONY_SERVER_BUILDER=native make server

Override manual:
  SYNCFONY_SERVER_BUILDER=cross scripts/build-server.sh aarch64-unknown-linux-gnu
EOF
    exit 1
    ;;
esac

if [ ! -f "$BIN" ]; then
  echo "✗ binary tidak ditemukan: $BIN" >&2
  echo "  Cek keluaran build di atas; kalau gagal karena libheif," >&2
  echo "  coba SYNCFONY_SERVER_BUILDER=native di mesin Linux target." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
DEST="$OUT_DIR/syncfony-server-$VERSION-$SUFFIX"
cp "$BIN" "$DEST"

# llvm-strip bisa menangani binary lintas arsitektur, sedangkan strip bawaan macOS tidak.
if have llvm-strip; then
  llvm-strip --strip-all "$DEST" 2>/dev/null || true
fi
chmod +x "$DEST"

SIZE=$(ls -lh "$DEST" | awk '{print $5}')
echo "✓ $DEST ($SIZE)"
