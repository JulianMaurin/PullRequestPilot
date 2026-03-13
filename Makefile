SCHEME       := PullRequestPilot
PROJECT      := PullRequestPilot.xcodeproj
APP_NAME     := Pull Request Pilot.app
BUNDLE_NAME  := PullRequestPilot.app
INSTALL_DIR  := /Applications
BUILD_DIR    := .build
CONFIG       := Release

export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

XCODEBUILD_BASE := xcodebuild -scheme $(SCHEME) -project $(PROJECT) \
	-destination 'platform=macOS'
XCODEBUILD := $(XCODEBUILD_BASE) -configuration $(CONFIG)

.PHONY: all generate build install uninstall clean test run debug reset

all: build

# Regenerate Xcode project from project.yml
generate:
	xcodegen generate

# Build release
build: generate
	$(XCODEBUILD) build SYMROOT=$(BUILD_DIR)

# Install to /Applications
install: build
	@echo "Installing to $(INSTALL_DIR)/$(APP_NAME)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@cp -R "$(BUILD_DIR)/$(CONFIG)/$(BUNDLE_NAME)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Done. Launch from Applications or Spotlight."

# Remove from /Applications
uninstall:
	@echo "Removing $(INSTALL_DIR)/$(APP_NAME)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Done."

# Build debug and run (reads GITHUB_TOKEN from .env)
debug: generate
	$(XCODEBUILD_BASE) -configuration Debug build SYMROOT=$(BUILD_DIR)
	@if [ -f .env ]; then \
		set -a && . ./.env && set +a && \
		"$(BUILD_DIR)/Debug/$(BUNDLE_NAME)/Contents/MacOS/PullRequestPilot"; \
	else \
		open "$(BUILD_DIR)/Debug/$(BUNDLE_NAME)"; \
	fi

# Build release and run
run: build
	@open "$(BUILD_DIR)/$(CONFIG)/$(BUNDLE_NAME)"

# Run tests
test: generate
	$(XCODEBUILD_BASE) -configuration Debug test

# Clean build artifacts
clean:
	$(XCODEBUILD) clean
	rm -rf $(BUILD_DIR)

# Full reset — simulate a first install by removing the app, its data, and keychain token
BUNDLE_ID    := com.pullrequestpilot.app
APP_GROUP_ID := FNR3B372S8.com.pullrequestpilot.shared
reset: uninstall
	@echo "Removing UserDefaults for $(BUNDLE_ID)..."
	@defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@echo "Removing app group container..."
	@rm -rf "$(HOME)/Library/Group Containers/$(APP_GROUP_ID)"
	@echo "Removing app containers..."
	@rm -rf "$(HOME)/Library/Containers/$(BUNDLE_ID)" 2>/dev/null || true
	@echo "Removing Keychain token..."
	@security delete-generic-password -s $(BUNDLE_ID) 2>/dev/null || true
	@echo "Removing DerivedData..."
	@rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/PullRequestPilot-*
	@echo "Reset complete — next launch will behave like a fresh install."
