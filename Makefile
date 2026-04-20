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

.PHONY: all generate lint lint-errors-only build install uninstall clean test run debug reinstall nuke

all: build

# Regenerate Xcode project from project.yml
generate:
	xcodegen generate

# Lint — fails on any rule defined in .swiftlint.yml
# Requires: brew install swiftlint
lint:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed — run: brew install swiftlint"; exit 1; }
	swiftlint lint --strict --quiet

# Lint but suppress warnings (developer iteration loop)
lint-errors-only:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed — run: brew install swiftlint"; exit 1; }
	swiftlint lint --quiet

# Build release
build: generate lint
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
test: generate lint
	$(XCODEBUILD_BASE) -configuration Debug test

# Clean build artifacts
clean:
	$(XCODEBUILD) clean
	rm -rf $(BUILD_DIR)

# Reinstall — clear widget caches and reinstall the app (preserves token and data)
reinstall: uninstall
	@echo "Killing widget and Xcode indexer processes..."
	@killall NotificationCenter 2>/dev/null || true
	@killall PullRequestPilotWidgetExtension 2>/dev/null || true
	@killall com.apple.dt.SKAgent 2>/dev/null || true
	@$(MAKE) install
	@echo "Clearing DerivedData (removes stale debug widget extensions)..."
	@rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/PullRequestPilot-* 2>/dev/null || true

# Nuke — wipe everything (app, data, token) for a clean first-launch experience
BUNDLE_ID    := com.pullrequestpilot.app
APP_GROUP_ID := FNR3B372S8.com.pullrequestpilot.shared
nuke: uninstall
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
	@echo "Killing NotificationCenter to flush widget cache..."
	@killall NotificationCenter 2>/dev/null || true
	@echo "Nuke complete — next launch will behave like a fresh install."
