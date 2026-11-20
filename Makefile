# ============================================================================
# Syncfony build system
#   server : Rust (Axum + SurrealKV)  -> linux/arm64 + linux/x86_64
#   client : Flutter                  -> APK (Android) + IPA (iOS, macOS only)
#   hasil  : ./output
#
#   make              # server (2 arsitektur) + app + checksums
#   make server       # binary server untuk Debian arm64 & x86_64
#   make app          # APK (+ IPA bila dijalankan di macOS)
#   make help         # daftar target
# ============================================================================

SHELL         := /bin/sh
.DEFAULT_GOAL := help

ROOT           := $(CURDIR)
OUT            := $(ROOT)/output
SERVER_DIR     := $(ROOT)/server
CLIENT_DIR     := $(ROOT)/client
APP_NAME       := syncfony

ARM64_TARGET   := aarch64-unknown-linux-gnu
X86_64_TARGET  := x86_64-unknown-linux-gnu

APP_VERSION    := $(shell sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' $(CLIENT_DIR)/pubspec.yaml 2>/dev/null | head -n1)
SERVER_VERSION := $(shell sed -n 's/^version *= *"\([^"]*\)".*/\1/p' $(SERVER_DIR)/Cargo.toml 2>/dev/null | head -n1)
BUILD_NUMBER   ?= $(shell date +%Y%m%d%H%M)

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

ifeq ($(HOST_OS),Darwin)
APP_TARGETS := apk ipa
APP_HELP    := + IPA
else
APP_TARGETS := apk
APP_HELP    := (IPA hanya di macOS)
endif

.PHONY: help all server server-arm64 server-x86_64 server-native \
        app apk ipa ios-unsigned checksums doctor clean clean-build

# ---------------------------------------------------------------------------
help:
	@echo ""
	@echo "  Syncfony build ($(HOST_OS) $(HOST_ARCH))"
	@echo "  app v$(APP_VERSION)  •  server v$(SERVER_VERSION)"
	@echo ""
	@echo "  make all            server (arm64+x86_64) + app + checksums"
	@echo "  make server         binary server Debian arm64 & x86_64"
	@echo "  make server-arm64   hanya linux/arm64   (Raspberry Pi / VPS ARM)"
	@echo "  make server-x86_64  hanya linux/x86_64  (Debian/Ubuntu AMD-Intel)"
	@echo "  make server-native  binary untuk mesin ini (untuk uji lokal)"
	@echo ""
	@echo "  make app            APK $(APP_HELP)"
	@echo "  make apk            APK universal (release)"
	@echo "  make ipa            IPA release bertanda tangan (butuh Xcode + sertifikat)"
	@echo "  make ios-unsigned   IPA tanpa tanda tangan (sideload, tetap butuh macOS)"
	@echo ""
	@echo "  make doctor         cek tool yang tersedia"
	@echo "  make checksums      hitung ulang output/SHA256SUMS"
	@echo "  make clean          hapus isi output/"
	@echo "  make clean-build    output/ + cargo clean + flutter clean"
	@echo ""

all: server app checksums
	@echo ""
	@echo "✓ selesai. artefak ada di $(OUT):"
	@ls -lh $(OUT) | sed 's/^/   /'
	@echo ""

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
server: server-arm64 server-x86_64

server-arm64:
	@$(ROOT)/scripts/build-server.sh $(ARM64_TARGET)

server-x86_64:
	@$(ROOT)/scripts/build-server.sh $(X86_64_TARGET)

server-native:
	@echo "→ cargo build --release (native)"
	@( cd $(SERVER_DIR) && cargo build --release )
	@mkdir -p $(OUT)
	@cp $(SERVER_DIR)/target/release/syncfony \
	    $(OUT)/$(APP_NAME)-server-$(SERVER_VERSION)-native-$(HOST_OS)-$(HOST_ARCH)
	@chmod +x $(OUT)/$(APP_NAME)-server-$(SERVER_VERSION)-native-$(HOST_OS)-$(HOST_ARCH)
	@ls -lh $(OUT)/$(APP_NAME)-server-$(SERVER_VERSION)-native-$(HOST_OS)-$(HOST_ARCH)

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------
app: $(APP_TARGETS)

apk:
	@command -v flutter >/dev/null 2>&1 || { \
	  echo "✗ flutter tidak ditemukan di PATH"; exit 1; }
	@echo "→ flutter build apk (v$(APP_VERSION)+$(BUILD_NUMBER))"
	@( cd $(CLIENT_DIR) && flutter pub get )
	@( cd $(CLIENT_DIR) && flutter build apk --release \
	    --build-name=$(APP_VERSION) --build-number=$(BUILD_NUMBER) )
	@mkdir -p $(OUT)
	@cp $(CLIENT_DIR)/build/app/outputs/flutter-apk/app-release.apk \
	    $(OUT)/$(APP_NAME)-$(APP_VERSION)-android.apk
	@ls -lh $(OUT)/$(APP_NAME)-$(APP_VERSION)-android.apk

ipa:
	@if [ "$(HOST_OS)" != "Darwin" ]; then \
	  echo "✗ IPA hanya bisa dibangun di macOS"; exit 1; fi
	@command -v flutter >/dev/null 2>&1 || { \
	  echo "✗ flutter tidak ditemukan di PATH"; exit 1; }
	@echo "→ flutter build ipa (v$(APP_VERSION)+$(BUILD_NUMBER))"
	@( cd $(CLIENT_DIR) && flutter pub get )
	@( cd $(CLIENT_DIR) && flutter build ipa --release \
	    --build-name=$(APP_VERSION) --build-number=$(BUILD_NUMBER) ) || { \
	  echo ""; \
	  echo "✗ flutter build ipa gagal. Kalau masalahnya code signing,"; \
	  echo "  jalankan 'make ios-unsigned' untuk IPA tanpa tanda tangan."; \
	  exit 1; }
	@mkdir -p $(OUT)
	@f=$$(ls -1 $(CLIENT_DIR)/build/ios/ipa/*.ipa 2>/dev/null | head -n1); \
	 if [ -z "$$f" ]; then echo "✗ tidak ada berkas .ipa"; exit 1; fi; \
	 cp "$$f" $(OUT)/$(APP_NAME)-$(APP_VERSION)-ios.ipa; \
	 ls -lh $(OUT)/$(APP_NAME)-$(APP_VERSION)-ios.ipa

ios-unsigned:
	@if [ "$(HOST_OS)" != "Darwin" ]; then \
	  echo "✗ iOS hanya bisa dibangun di macOS"; exit 1; fi
	@echo "→ flutter build ios --no-codesign"
	@( cd $(CLIENT_DIR) && flutter pub get )
	@( cd $(CLIENT_DIR) && flutter build ios --release --no-codesign \
	    --build-name=$(APP_VERSION) --build-number=$(BUILD_NUMBER) )
	@mkdir -p $(OUT)
	@rm -rf $(OUT)/.ipa-tmp
	@mkdir -p $(OUT)/.ipa-tmp/Payload
	@cp -R $(CLIENT_DIR)/build/ios/iphoneos/Runner.app $(OUT)/.ipa-tmp/Payload/
	@( cd $(OUT)/.ipa-tmp && zip -qry \
	    $(OUT)/$(APP_NAME)-$(APP_VERSION)-ios-unsigned.ipa Payload )
	@rm -rf $(OUT)/.ipa-tmp
	@ls -lh $(OUT)/$(APP_NAME)-$(APP_VERSION)-ios-unsigned.ipa

# ---------------------------------------------------------------------------
# Util
# ---------------------------------------------------------------------------
checksums:
	@mkdir -p $(OUT)
	@cd $(OUT) && sh -c 'if command -v sha256sum >/dev/null 2>&1; then S=sha256sum; \
	  else S="shasum -a 256"; fi; \
	  for f in *; do \
	    [ -f "$$f" ] || continue; \
	    [ "$$f" = "SHA256SUMS" ] && continue; \
	    $$S "$$f"; \
	  done > SHA256SUMS; \
	  if [ -s SHA256SUMS ]; then cat SHA256SUMS; \
	  else rm -f SHA256SUMS; echo "belum ada artefak di output/"; fi'

doctor:
	@echo "host          : $(HOST_OS) $(HOST_ARCH)"
	@printf 'rustc        : '; command -v rustc >/dev/null 2>&1 && rustc -V || echo missing
	@printf 'cargo        : '; command -v cargo >/dev/null 2>&1 && cargo -V || echo missing
	@printf 'cross        : '; command -v cross >/dev/null 2>&1 && echo "ada ($(shell cross --version 2>/dev/null | head -n1))" || echo "tidak ada (cargo install cross --locked)"
	@printf 'cargo-zigbuild: '; command -v cargo-zigbuild >/dev/null 2>&1 && echo ada || echo "tidak ada (cargo install cargo-zigbuild)"
	@printf 'zig          : '; command -v zig >/dev/null 2>&1 && zig version || echo "tidak ada (brew install zig)"
	@printf 'docker       : '; command -v docker >/dev/null 2>&1 && echo ada || echo "tidak ada"
	@printf 'flutter      : '; command -v flutter >/dev/null 2>&1 && echo ada || echo "tidak ada"
	@printf 'xcodebuild   : '; command -v xcodebuild >/dev/null 2>&1 && echo ada || echo "tidak ada"

clean:
	@rm -rf $(OUT)
	@echo "✓ $(OUT) dihapus"

clean-build: clean
	@( cd $(SERVER_DIR) && cargo clean )
	@( cd $(CLIENT_DIR) && flutter clean )
	@echo "✓ build cache bersih"
