APP_NAME    = VoiceInput
VERSION     = 1.0
BUILD_DIR   = .build/release
DIST_DIR    = dist
APP_BUNDLE  = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications

.PHONY: build run install clean release

# ── 默认构建（当前机器原生架构）──────────────────────────────────────
build:
	swift build -c release
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

# ── Release：构建三个架构并打包 zip ──────────────────────────────────
release: clean-dist build-arm64 build-x86_64 build-universal
	@echo "\n✓ Release artifacts in $(DIST_DIR)/"
	@ls -lh $(DIST_DIR)/

clean-dist:
	rm -rf $(DIST_DIR)
	mkdir -p $(DIST_DIR)

build-arm64:
	@echo "→ Building arm64..."
	swift build -c release --arch arm64
	$(call bundle_app,.build/arm64-apple-macosx/release/$(APP_NAME),$(DIST_DIR)/$(APP_NAME)-arm64.app)
	cd $(DIST_DIR) && zip -qr $(APP_NAME)-$(VERSION)-arm64.zip $(APP_NAME)-arm64.app
	rm -rf $(DIST_DIR)/$(APP_NAME)-arm64.app
	@echo "  arm64 done"

build-x86_64:
	@echo "→ Building x86_64..."
	swift build -c release --arch x86_64
	$(call bundle_app,.build/x86_64-apple-macosx/release/$(APP_NAME),$(DIST_DIR)/$(APP_NAME)-x86_64.app)
	cd $(DIST_DIR) && zip -qr $(APP_NAME)-$(VERSION)-x86_64.zip $(APP_NAME)-x86_64.app
	rm -rf $(DIST_DIR)/$(APP_NAME)-x86_64.app
	@echo "  x86_64 done"

build-universal:
	@echo "→ Building Universal (arm64 + x86_64)..."
	lipo -create \
		.build/arm64-apple-macosx/release/$(APP_NAME) \
		.build/x86_64-apple-macosx/release/$(APP_NAME) \
		-output $(DIST_DIR)/$(APP_NAME)-universal-bin
	$(call bundle_app,$(DIST_DIR)/$(APP_NAME)-universal-bin,$(DIST_DIR)/$(APP_NAME)-universal.app)
	rm -f $(DIST_DIR)/$(APP_NAME)-universal-bin
	cd $(DIST_DIR) && zip -qr $(APP_NAME)-$(VERSION)-universal.zip $(APP_NAME)-universal.app
	rm -rf $(DIST_DIR)/$(APP_NAME)-universal.app
	@echo "  Universal done"

# ── 通用 bundle 函数：$(1)=二进制路径, $(2)=.app目标路径 ─────────────
define bundle_app
	rm -rf "$(2)"
	mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	cp "$(1)" "$(2)/Contents/MacOS/$(APP_NAME)"
	cp Sources/$(APP_NAME)/Info.plist "$(2)/Contents/Info.plist"
	cp Sources/$(APP_NAME)/AppIcon.icns "$(2)/Contents/Resources/AppIcon.icns"
	cp -R Resources/*.lproj "$(2)/Contents/Resources/"
	codesign --force --sign - --entitlements VoiceInput.entitlements "$(2)"
endef
