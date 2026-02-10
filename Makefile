APP_NAME = Speek
SCHEME = Speek
PROJECT = Speek.xcodeproj
CONFIG = Release
BUILD_DIR = $(CURDIR)/build
INSTALL_DIR = /Applications

.PHONY: build install uninstall clean reset-permissions

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		build

install: build
	@# Find the built .app bundle
	$(eval APP_PATH := $(shell find $(BUILD_DIR) -name "$(APP_NAME).app" -path "*/$(CONFIG)/*" | head -1))
	@if [ -z "$(APP_PATH)" ]; then echo "Error: $(APP_NAME).app not found in build output"; exit 1; fi
	@echo "Installing $(APP_PATH) → $(INSTALL_DIR)/$(APP_NAME).app"
	@-pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_PATH)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@# Reset accessibility permission so macOS re-prompts for the new binary
	@-tccutil reset Accessibility com.speek.app 2>/dev/null
	@echo "Accessibility permission reset — you will be prompted to re-grant on first use"

uninstall:
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf $(BUILD_DIR)
