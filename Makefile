APP_NAME    = AtomVoice
SRC_DIR     = Sources/AtomVoice
VERSION     = 0.10.4-Beta-4
BUILD_DIR   = .build/release
DIST_DIR    = dist
APP_BUNDLE  = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications
SHERPA_MEMORY_PROVIDERS ?= cpu,coreml
SHERPA_MEMORY_RUNS ?= 3

.PHONY: build dev run install clean release sherpa-memory test lint-loc

# ── 开发调试构建：安装到 dist/Test/（供确认后使用）──────────────────
dev:
	swift build -c release --product $(APP_NAME) -Xswiftc -DDEBUG_BUILD
	$(call bundle_app,$(BUILD_DIR)/$(APP_NAME),$(DIST_DIR)/Test/$(APP_NAME).app)
	@echo "Dev build: $(DIST_DIR)/Test/$(APP_NAME).app"

# ── 默认构建（当前机器原生架构，含 DEBUG_BUILD 标记）────────────────
build:
	swift build -c release --product $(APP_NAME) -Xswiftc -DDEBUG_BUILD
	$(call bundle_app,$(BUILD_DIR)/$(APP_NAME),$(APP_BUNDLE))
	@echo "Built: $(APP_BUNDLE)"

run: build
	open "$(APP_BUNDLE)"

install: build
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf .build $(DIST_DIR)

test:
	swift run -Xswiftc -enable-testing AtomVoiceArchitectureTests

lint-loc:
	swift Scripts/check_localization.swift

# ── Debug-only Sherpa model memory benchmark ────────────────────────────────
sherpa-memory:
	mkdir -p $(DIST_DIR)
	swift build -c release --product SherpaMemoryProbe -Xswiftc -DDEBUG_BUILD
	swift build -c release --product SherpaMemoryBenchmark -Xswiftc -DDEBUG_BUILD
	.build/release/SherpaMemoryBenchmark --providers "$(or $(PROVIDERS),$(SHERPA_MEMORY_PROVIDERS))" --runs $(or $(RUNS),$(SHERPA_MEMORY_RUNS)) --output-dir "$(DIST_DIR)" $(if $(AUDIO),--audio "$(AUDIO)",)

# ── Release：构建三个正式包 + 一个 Debug Universal 包并打包 zip ───────
release: clean-dist build-arm64 build-x86_64 build-universal build-debug-universal sha256sums
	@echo "\n✓ Release artifacts in $(DIST_DIR)/"
	@ls -lh $(DIST_DIR)/

# ── 生成 SHA256 校验文件，供客户端自动更新校验 ───────────────────────
sha256sums:
	@echo "→ Generating SHA256SUMS.txt..."
	cd $(DIST_DIR) && shasum -a 256 *.zip > SHA256SUMS.txt
	@cat $(DIST_DIR)/SHA256SUMS.txt

clean-dist:
	rm -rf $(DIST_DIR)
	mkdir -p $(DIST_DIR)

build-arm64:
	@echo "→ Building Apple Silicon (arm64)..."
	swift build -c release --product $(APP_NAME) --arch arm64
	$(call bundle_app,.build/arm64-apple-macosx/release/$(APP_NAME),$(DIST_DIR)/$(APP_NAME).app)
	cd $(DIST_DIR) && zip -qr "$(APP_NAME)-$(VERSION)-AppleSilicon.zip" $(APP_NAME).app
	rm -rf $(DIST_DIR)/$(APP_NAME).app
	@echo "  Apple Silicon done"

build-x86_64:
	@echo "→ Building Intel (x86_64)..."
	swift build -c release --product $(APP_NAME) --arch x86_64
	$(call bundle_app,.build/x86_64-apple-macosx/release/$(APP_NAME),$(DIST_DIR)/$(APP_NAME).app)
	cd $(DIST_DIR) && zip -qr "$(APP_NAME)-$(VERSION)-Intel.zip" $(APP_NAME).app
	rm -rf $(DIST_DIR)/$(APP_NAME).app
	@echo "  Intel done"

build-universal:
	@echo "→ Building Universal (Apple Silicon + Intel)..."
	lipo -create \
		.build/arm64-apple-macosx/release/$(APP_NAME) \
		.build/x86_64-apple-macosx/release/$(APP_NAME) \
		-output $(DIST_DIR)/$(APP_NAME)-universal-bin
	$(call bundle_app,$(DIST_DIR)/$(APP_NAME)-universal-bin,$(DIST_DIR)/$(APP_NAME).app)
	rm -f $(DIST_DIR)/$(APP_NAME)-universal-bin
	cd $(DIST_DIR) && zip -qr "$(APP_NAME)-$(VERSION)-Universal.zip" $(APP_NAME).app
	rm -rf $(DIST_DIR)/$(APP_NAME).app
	@echo "  Universal done"

build-debug-universal:
	@echo "→ Building Debug Universal (Apple Silicon + Intel)..."
	swift build -c release --product $(APP_NAME) --arch arm64 -Xswiftc -DDEBUG_BUILD
	swift build -c release --product $(APP_NAME) --arch x86_64 -Xswiftc -DDEBUG_BUILD
	lipo -create \
		.build/arm64-apple-macosx/release/$(APP_NAME) \
		.build/x86_64-apple-macosx/release/$(APP_NAME) \
		-output $(DIST_DIR)/$(APP_NAME)-debug-universal-bin
	$(call bundle_app,$(DIST_DIR)/$(APP_NAME)-debug-universal-bin,$(DIST_DIR)/$(APP_NAME).app)
	rm -f $(DIST_DIR)/$(APP_NAME)-debug-universal-bin
	cd $(DIST_DIR) && zip -qr "$(APP_NAME)-$(VERSION)-Debug-Universal.zip" $(APP_NAME).app
	rm -rf $(DIST_DIR)/$(APP_NAME).app
	@echo "  Debug Universal done"

# ── 通用 bundle 函数：$(1)=二进制路径, $(2)=.app目标路径 ─────────────
define bundle_app
	rm -rf "$(2)"
	mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	cp "$(1)" "$(2)/Contents/MacOS/$(APP_NAME)"
	cp $(SRC_DIR)/Info.plist "$(2)/Contents/Info.plist"
	cp $(SRC_DIR)/AppIcon.icns "$(2)/Contents/Resources/AppIcon.icns"
	cp -R Resources/*.lproj "$(2)/Contents/Resources/"
	cp -R Resources/Icons "$(2)/Contents/Resources/"
	find "$(2)/Contents/Resources" -name "*.strings" | while read f; do printf '\xef\xbb\xbf' > "$$f.tmp" && cat "$$f" >> "$$f.tmp" && mv "$$f.tmp" "$$f"; done
	codesign --force --sign "Apple Development: miaolingru@gmail.com (XJS89V9J9T)" --entitlements AtomVoice.entitlements "$(2)"
endef
