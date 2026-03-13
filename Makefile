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

.PHONY: all generate build install uninstall clean test run debug

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
