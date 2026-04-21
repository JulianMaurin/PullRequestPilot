SHELL        := /bin/bash
.SHELLFLAGS  := -o pipefail -c

SCHEME       := PullRequestPilot
PROJECT      := PullRequestPilot.xcodeproj
APP_NAME     := Pull Request Pilot.app
BUNDLE_NAME  := PullRequestPilot.app
INSTALL_DIR  := /Applications
BUILD_DIR    := .build
CONFIG       := Release

export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

XCODEBUILD_BASE := xcodebuild -scheme $(SCHEME) -project $(PROJECT) \
	-destination 'generic/platform=macOS'
XCODEBUILD := $(XCODEBUILD_BASE) -configuration $(CONFIG)

XCB_FILTER := scripts/xcb-filter.sh

SWIFT_SOURCES := $(sort $(shell find PullRequestPilot Shared PullRequestPilotTests PullRequestPilotWidget -type f -name '*.swift' 2>/dev/null))
SWIFT_SOURCES_STAMP := $(BUILD_DIR)/.swift-sources.stamp

.PHONY: all generate lint lint-errors-only build install uninstall clean clean-deep test run debug reinstall nuke metadata-lint release-check FORCE

all: build

# Keep a stamp file whose mtime changes only when the .swift file list does —
# this lets project.pbxproj regenerate on add AND delete.
$(SWIFT_SOURCES_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s\n' $(SWIFT_SOURCES) > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm -f $@.tmp; else mv $@.tmp $@; fi

FORCE:

$(PROJECT)/project.pbxproj: project.yml $(SWIFT_SOURCES) $(SWIFT_SOURCES_STAMP)
	@command -v xcodegen >/dev/null || { echo "xcodegen not installed — run: brew install xcodegen"; exit 1; }
	xcodegen generate

# Phony alias for callers that expect `make generate`
generate: $(PROJECT)/project.pbxproj

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
build: $(PROJECT)/project.pbxproj lint
	$(XCODEBUILD) build SYMROOT=$(BUILD_DIR) 2>&1 | $(XCB_FILTER)

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
debug: $(PROJECT)/project.pbxproj
	$(XCODEBUILD_BASE) -configuration Debug build SYMROOT=$(BUILD_DIR) 2>&1 | $(XCB_FILTER)
	@if [ -f .env ]; then \
		set -a && . ./.env && set +a && \
		"$(BUILD_DIR)/Debug/$(BUNDLE_NAME)/Contents/MacOS/PullRequestPilot"; \
	else \
		open "$(BUILD_DIR)/Debug/$(BUNDLE_NAME)"; \
	fi

# Build release and run
run: build
	@open "$(BUILD_DIR)/$(CONFIG)/$(BUNDLE_NAME)"

# Run tests — Xcode requires a concrete device for `test`, not `generic/platform`.
# arch disambiguates when multiple macOS destinations match (Catalyst, Designed for iPad).
HOST_ARCH := $(shell uname -m)
test: $(PROJECT)/project.pbxproj lint
	xcodebuild -scheme $(SCHEME) -project $(PROJECT) \
		-destination 'platform=macOS,arch=$(HOST_ARCH)' -configuration Debug test 2>&1 | $(XCB_FILTER)

# Clean build artifacts
clean:
	$(XCODEBUILD) clean
	rm -rf $(BUILD_DIR)

# Deep clean — use when Xcode and reality diverge (stale indexer, ghost errors,
# widget cache shadows). Nukes DerivedData and Xcode caches, kicks
# NotificationCenter to flush widget registrations.
clean-deep: clean
	@echo "Removing DerivedData..."
	@rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/PullRequestPilot-*
	@echo "Removing Xcode caches..."
	@rm -rf $(HOME)/Library/Caches/com.apple.dt.Xcode
	@echo "Killing NotificationCenter to flush widget cache..."
	@killall NotificationCenter 2>/dev/null || true
	@echo "Deep clean complete."

# App Store metadata lint — forbidden terms, subtitle length, version monotonicity
metadata-lint:
	@scripts/metadata-lint.sh

# Pre-submission gate — runs everything and reports a manual checklist at the end
release-check:
	@scripts/release-check.sh

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
LSREGISTER   := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
nuke:
	@echo "Quitting running app + widget (otherwise they re-register notifications while we purge)..."
	@killall PullRequestPilot 2>/dev/null || true
	@killall PullRequestPilotWidgetExtension 2>/dev/null || true
	@# Give launchd a moment to notice the exit so it doesn't respawn the widget.
	@sleep 1
	@echo "Unregistering installed app from Launch Services (before removal)..."
	@$(LSREGISTER) -u "$(INSTALL_DIR)/$(APP_NAME)" 2>/dev/null || true
	@echo "Removing $(INSTALL_DIR)/$(APP_NAME)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Removing UserDefaults for $(BUNDLE_ID)..."
	@defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@echo "Removing app group container..."
	@rm -rf "$(HOME)/Library/Group Containers/$(APP_GROUP_ID)" 2>/dev/null || \
		echo "  (protected by macOS App Management — grant Terminal permission in System Settings › Privacy & Security › App Management to clear)"
	@echo "Removing all app containers (main, widget, test variants)..."
	@for dir in $(BUNDLE_ID) $(BUNDLE_ID).widget $(BUNDLE_ID).test $(BUNDLE_ID).test.widget; do \
		rm -rf "$(HOME)/Library/Containers/$$dir" 2>/dev/null || echo "  (skipped $$dir — protected)"; \
	done
	@echo "Removing Application Scripts directories..."
	@for dir in $(BUNDLE_ID) $(BUNDLE_ID).widget $(BUNDLE_ID).test $(BUNDLE_ID).test.widget $(APP_GROUP_ID); do \
		rm -rf "$(HOME)/Library/Application Scripts/$$dir" 2>/dev/null || echo "  (skipped $$dir — protected)"; \
	done
	@echo "Removing Keychain token..."
	@security delete-generic-password -s $(BUNDLE_ID) 2>/dev/null || true
	@echo "Removing DerivedData..."
	@rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/PullRequestPilot-*
	@echo "Resetting TCC permissions (microphone/camera/full-disk — not notifications)..."
	@tccutil reset All $(BUNDLE_ID) 2>/dev/null || true
	@tccutil reset All $(BUNDLE_ID).widget 2>/dev/null || true
	@echo "Rebuilding Launch Services database (purges stale NOTIFICATION# activity types)..."
	@$(LSREGISTER) -kill -r -domain user 2>/dev/null || true
	@# Notifications MUST come LAST. Rebuilding Launch Services above re-processes
	@# the app's old NOTIFICATION# activity type and BTM reconciles its login-item
	@# record, both of which cause usernoted to re-register the bundle with auth=6
	@# via designated-requirement match. If we purged notifications first, that
	@# re-registration would defeat the purge — observed as needing 2-3 successive
	@# `make nuke` runs before the auth plist stayed clean.
	@echo "Purging notification authorization state (ncprefs + usernoted plist + db)..."
	@scripts/nuke-notifications.sh \
		$(BUNDLE_ID) \
		$(BUNDLE_ID).widget \
		$(BUNDLE_ID).test \
		$(BUNDLE_ID).test.widget
	@echo "Nuke complete — next launch will behave like a fresh install."
