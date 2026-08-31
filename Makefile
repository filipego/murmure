EXEC     := MurmurYouTube
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/MurmurYouTubeBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)
HELPER_BUILD := $(SCRATCH)/$(CONFIG)/MurmurUpdateHelper
TEST_SCRATCH := $(HOME)/Library/Caches/MurmurYouTubeBuild/test-scratch
INTEL_PROBE = $(STAGE)/MurmureIntelSpeechProbe

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/MurmurYouTubeBuild
APPNAME  := Murmure.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents
HELPERS  := $(CONTENTS)/Helpers
INBOX    := $(HOME)/Library/Application Support/MurmurYouTube/Updates
DIST     := dist
PINNED_REQUIREMENT := identifier "ai.pivotstudio.murmur-youtube" and certificate root = H"dd1175e05550d5ff2ac47ca8621caf97be7ab707"

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Prefer a stable
## Developer ID, then a stable local signing certificate already present on this Mac. Fall
## back to ad-hoc ("-") only when neither identity is available.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Local Signing" | head -1 | sed -E 's/.*"(.*)".*/\1/')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all test build app run install intel-probe require-stable-update-signing stage-update share release clean icon

all: app

test:
	swift test --scratch-path "$(TEST_SCRATCH)"

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)" --product $(EXEC)
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)" --product MurmurUpdateHelper

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(HELPERS)"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp "$(HELPER_BUILD)" "$(HELPERS)/MurmurUpdateHelper"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp Sources/MurmurYouTube/Localization/catalog.tsv "$(CONTENTS)/Resources/catalog.tsv"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--options runtime \
		--timestamp=none \
		"$(HELPERS)/MurmurUpdateHelper"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Only ever targets the MurmurYouTube executable — never the separate `murmur` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Installing to /Applications keeps the path stable. With a stable signing identity, the
## Accessibility grant survives rebuilds and local updates; ad-hoc fallback signatures do not.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

intel-probe:
	@mkdir -p "$(STAGE)"
	@xcrun swiftc \
		-parse-as-library \
		-swift-version 6 \
		-strict-concurrency=complete \
		-warnings-as-errors \
		-target x86_64-apple-macosx15.0 \
		-framework Speech \
		-Xlinker -sectcreate \
		-Xlinker __TEXT \
		-Xlinker __info_plist \
		-Xlinker Resources/IntelSpeechProbe-Info.plist \
		Tools/IntelSpeechProbe.swift \
		-o "$(INTEL_PROBE)"
	@codesign --force --sign "$(SIGN_ID)" --timestamp=none "$(INTEL_PROBE)"
	@ARCHS=$$(lipo -archs "$(INTEL_PROBE)"); \
		[ "$$ARCHS" = 'x86_64' ] || { echo "unexpected probe architecture: $$ARCHS" >&2; exit 1; }
	@echo "built $(INTEL_PROBE) for x86_64 macOS 15"

## Stage the freshly built app in the local update inbox. The coordinator only accepts a
## bundle inside this directory, so a manifest copied from another location cannot be used
## accidentally. `plutil` writes JSON with the exact Codable shape expected by Swift.
require-stable-update-signing:
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo "stage-update requires a stable code-signing identity; install or select a Developer ID or Local Signing certificate." >&2; \
		exit 1; \
	fi

stage-update: require-stable-update-signing app
	@mkdir -p "$(INBOX)"
	@set -e; STAGED="$(INBOX)/$(APPNAME)"; \
		rm -rf "$$STAGED"; \
		ditto "$(BUNDLE)" "$$STAGED"; \
		MANIFEST_PLIST="$(INBOX)/manifest.plist"; \
		rm -f "$$MANIFEST_PLIST"; \
		STAGED_URL=$$(printf 'file://%s' "$$STAGED" | sed 's/ /%20/g;s/#/%23/g'); \
		VERSION=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(CONTENTS)/Info.plist"); \
		BUILD_NUMBER=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(CONTENTS)/Info.plist"); \
		/usr/bin/plutil -create xml1 "$$MANIFEST_PLIST"; \
		/usr/bin/plutil -insert bundleIdentifier -string 'ai.pivotstudio.murmur-youtube' "$$MANIFEST_PLIST"; \
		/usr/bin/plutil -insert version -xml '<dict></dict>' "$$MANIFEST_PLIST"; \
		/usr/bin/plutil -insert version.marketing -string "$$VERSION" "$$MANIFEST_PLIST"; \
		/usr/bin/plutil -insert version.build -integer "$$BUILD_NUMBER" "$$MANIFEST_PLIST"; \
		/usr/bin/plutil -insert stagedBundleURL -string "$$STAGED_URL" "$$MANIFEST_PLIST"; \
		/usr/bin/plutil -insert createdAt -string "$$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$MANIFEST_PLIST"; \
		/usr/bin/plutil -convert json -o "$(INBOX)/manifest.json" "$$MANIFEST_PLIST"; \
		rm -f "$$MANIFEST_PLIST"; \
		echo "staged update at $$STAGED"; \
		echo "manifest at $(INBOX)/manifest.json"

## Build a friend-shareable archive and write the install notes beside it. Signing is handled
## by `app`; the guide describes the actual identity and notarization boundary honestly.
share: app
	@mkdir -p "$(DIST)"
	@rm -f "$(DIST)/$(APPNAME).zip"
	@ditto -c -k --norsrc --keepParent "$(BUNDLE)" "$(DIST)/$(APPNAME).zip"
	@{ \
		echo '# Murmure'; \
		echo; \
		echo '**Requirements: Apple Silicon (M1 or newer) and macOS 26 or later.**'; \
		echo 'This modern archive does not support Intel Macs. Intel remains a separate hardware'; \
		echo 'compatibility investigation; do not bypass this requirement.'; \
		echo; \
		echo 'Download the latest release: https://github.com/filipego/murmure/releases/latest/download/Murmure.app.zip'; \
		echo; \
		echo '1. Unzip the archive and drag **Murmure.app** to `/Applications`.'; \
		echo '2. If macOS blocks the first launch, Control-click the app, choose Open, and confirm.'; \
		echo '   If needed, use System Settings → Privacy & Security → Open Anyway.'; \
		echo '3. Follow Set up Murmure. Grant Microphone and Accessibility access yourself, choose'; \
		echo '   a shortcut, test the microphone, choose language behavior, and finish one test.'; \
		echo '4. Automatic uses the free local Parakeet model to recognize 25 European languages.'; \
		echo '   The first use may download that model. Explicit languages can use Apple Speech.'; \
		echo '5. Hold the configured push-to-talk key in any app, speak, then finish the gesture.'; \
		echo '6. Later, use Settings → Updates → Check for updates → Install and relaunch.'; \
		echo '7. To correct a saved dictation, use the pencil Correct action on its history row.'; \
		echo '   Review "Murmure heard" and edit "I meant"; Play original is optional, and Dictate'; \
		echo '   only fills the draft. Remember is on by default, and Save correction is the only'; \
		echo '   action that persists history or a safe contextual local dictionary rule. An'; \
		echo '   interrupted rule stays pending in history and retries safely on the next launch.'; \
		echo '8. Command Mode edits selected text with Apple\047s on-device model. Select editable'; \
		echo '   text in another app, hold Control-Option-Command-D, speak the change, then release.'; \
		echo '   Review the proposal before replacing the selection, or copy it instead. Settings'; \
		echo '   explains if Apple Intelligence is unavailable. There is no network fallback.'; \
		echo; \
		echo 'Snippets replace an exact whole spoken phrase with reusable local text. Automatic'; \
		echo 'recognition, deterministic cleanup, snippets, dictionary corrections, history, and audio'; \
		echo 'all run locally. Model downloads and update checks are the only network operations.'; \
		echo; \
		echo 'Murmure stores settings, snippets, dictionary entries, transcript history, and captured'; \
		echo 'audio in its local data folder under Application Support. On the operator Mac only,'; \
		echo 'the specifically configured Extreme Pro drive is used when mounted. Settings always'; \
		echo 'shows the active location. Installation and app updates never replace that data folder,'; \
		echo 'and Murmure never removes unrelated drive files.'; \
		echo; \
		echo 'Use Settings → Setup and diagnostics to rerun setup or preview/copy/export a sanitized'; \
		echo 'report. Diagnostics contain app, Mac, engine, language, model, permission, microphone,'; \
		echo 'and storage status only. They never include dictated text, history, audio, snippets, dictionary data,'; \
		echo 'or local file paths.'; \
		echo; \
		echo 'The archive uses a stable Developer ID or local signing identity when available.'; \
		echo 'If neither is available, it falls back to ad-hoc signing and macOS may ask for'; \
		echo 'permissions again after a rebuild. This build'; \
		echo 'is not notarized unless a notarized artifact is explicitly supplied.'; \
	} > "$(DIST)/INSTALL.md"
	@(cd "$(DIST)" && shasum -a 256 "$(APPNAME).zip" > "$(APPNAME).zip.sha256")
	@echo "wrote $(DIST)/$(APPNAME).zip and $(DIST)/INSTALL.md"

## Produce and verify the exact assets consumed by the in-app GitHub Releases updater.
## A locally self-signed certificate reports CSSMERR_TP_NOT_TRUSTED to the system trust
## store; that single status is allowed only after strict integrity and exact requirement
## checks. Any other codesign failure remains fatal.
release: require-stable-update-signing
	@$(MAKE) share SIGN_ID="$(SIGN_ID)"
	@set -eu; verify_code() { \
		OUTPUT=$$(codesign --verify --deep --strict --verbose=2 "$$1" 2>&1) || STATUS=$$?; \
		STATUS=$${STATUS:-0}; \
		if [ "$$STATUS" -ne 0 ]; then \
			printf '%s\n' "$$OUTPUT" | grep -q 'CSSMERR_TP_NOT_TRUSTED' || { printf '%s\n' "$$OUTPUT" >&2; exit 1; }; \
			printf '%s\n' "$$OUTPUT" | grep -Eqi 'invalid|not signed|resource envelope|code object is not signed' && { printf '%s\n' "$$OUTPUT" >&2; exit 1; } || true; \
		fi; \
	}; \
	verify_code "$(BUNDLE)"; \
	verify_code "$(HELPERS)/MurmurUpdateHelper"; \
	ACTUAL=$$(codesign -d -r- "$(BUNDLE)" 2>&1 | sed -n 's/^designated => //p'); \
	[ "$$ACTUAL" = '$(PINNED_REQUIREMENT)' ] || { echo "unexpected release requirement: $$ACTUAL" >&2; exit 1; }; \
	ARCHS=$$(lipo -archs "$(CONTENTS)/MacOS/$(EXEC)"); \
	[ "$$ARCHS" = 'arm64' ] || { echo "unexpected release architectures: $$ARCHS" >&2; exit 1; }; \
	MIN_OS=$$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$(CONTENTS)/Info.plist"); \
	[ "$$MIN_OS" = '26.0' ] || { echo "unexpected minimum macOS version: $$MIN_OS" >&2; exit 1; }; \
	ROOTS=$$(unzip -Z1 "$(DIST)/$(APPNAME).zip" | sed 's#/.*##' | sort -u); \
	[ "$$ROOTS" = '$(APPNAME)' ] || { echo "archive contains unexpected roots: $$ROOTS" >&2; exit 1; }; \
	(cd "$(DIST)" && shasum -a 256 -c "$(APPNAME).zip.sha256"); \
	VERSION=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(CONTENTS)/Info.plist"); \
	BUILD_NUMBER=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(CONTENTS)/Info.plist"); \
	echo "release tag: v$$VERSION+$$BUILD_NUMBER"; \
	echo "release assets:"; \
	echo "requirements: Apple Silicon, macOS $$MIN_OS or later"; \
	echo "$(DIST)/$(APPNAME).zip"; \
	echo "$(DIST)/$(APPNAME).zip.sha256"; \
	echo "$(DIST)/INSTALL.md"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
