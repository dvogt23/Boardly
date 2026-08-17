# Boardly — build / run helpers.
#
# The single command you usually want:
#     make            # rebuild the app and open it on the simulator
#
# Override any knob on the command line, e.g.:
#     make SIM="iPhone 17" run
#     make LANG_ARGS='-AppleLanguages "(de)"' run   # run in German
#     make pseudo                                    # accented pseudolanguage pass

PROJECT      := Boardly/Boardly.xcodeproj
SCHEME       := Boardly
SIM          := iPhone 17 Pro
DESTINATION  := platform=iOS Simulator,name=$(SIM)
DERIVED_DATA := .build/xcode
APP          := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(SCHEME).app
# Deferred (`=`, not `:=`): read from the freshly built bundle so it can't drift from
# PRODUCT_BUNDLE_IDENTIFIER. Before the first build, fall back to the xcconfig chain —
# Local.xcconfig (developer override) first, then the tracked default.
BUNDLE_ID     = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                  "$(APP)/Info.plist" 2>/dev/null || \
                  sed -n 's/^BOARDLY_BUNDLE_ID *= *//p' \
                    Boardly/Config/Local.xcconfig Boardly/Config/Signing.xcconfig \
                    2>/dev/null | head -1)
# Extra launch arguments, e.g. -AppleLanguages "(de)" to force a locale.
LANG_ARGS    :=

# Quieter xcodebuild output when xcbeautify is installed; plain otherwise.
FORMATTER    := $(shell command -v xcbeautify >/dev/null 2>&1 && echo '| xcbeautify' || echo '')

.DEFAULT_GOAL := run
.PHONY: run build boot install launch open test test-app test-kit lint format strings pseudo clean help

## run: rebuild, install, and launch the app on the simulator
run: build boot install launch

## build: build the app for the simulator
build:
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) \
	  build $(FORMATTER)

## boot: boot the simulator and bring Simulator.app to the front
boot:
	open -a Simulator
	# `bootstatus -b` boots if needed and blocks until the device is usable —
	# retried once because a device still shutting down rejects the first boot.
	xcrun simctl bootstatus "$(SIM)" -b || xcrun simctl bootstatus "$(SIM)" -b

## install: install the last build onto the simulator
install:
	xcrun simctl install "$(SIM)" "$(APP)"

## launch: launch (relaunching if already running) the installed app
launch:
	xcrun simctl terminate "$(SIM)" "$(BUNDLE_ID)" 2>/dev/null || true
	xcrun simctl launch "$(SIM)" "$(BUNDLE_ID)" $(LANG_ARGS)

## open: open the Xcode project
open:
	open $(PROJECT)

## test: BoardlyKit unit tests + app unit tests
test: test-kit test-app

## test-kit: BoardlyKit (SwiftPM) unit tests
test-kit:
	swift test

## test-app: app-target unit tests on the simulator (UI tests excluded)
test-app:
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) \
	  -only-testing:BoardlyTests test $(FORMATTER)

## lint: SwiftFormat in lint mode + the localization guard (what CI runs)
lint:
	swiftformat --lint .
	python3 Scripts/check-localization.py

## format: apply SwiftFormat in place
format:
	swiftformat .

## strings: sync new source strings into Localizable.xcstrings (needs a build first)
strings: build
	xcrun xcstringstool sync Boardly/Boardly/Localizable.xcstrings \
	  $(shell find $(DERIVED_DATA) -name '*.stringsdata' -print 2>/dev/null | sed 's/^/--stringsdata /')

## pseudo: run the app under the accented pseudolanguage (localization leak check)
pseudo:
	$(MAKE) run LANG_ARGS='-AppleLanguages "(en-XA)"'

## clean: remove build products
clean:
	rm -rf $(DERIVED_DATA)
	swift package clean

## help: list the available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
