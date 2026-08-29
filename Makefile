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

.PHONY: all build app run install stage-update share clean icon

all: app

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

## Stage the freshly built app in the local update inbox. The coordinator only accepts a
## bundle inside this directory, so a manifest copied from another location cannot be used
## accidentally. `plutil` writes JSON with the exact Codable shape expected by Swift.
stage-update: app
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
	@ditto -c -k --sequesterRsrc --keepParent "$(BUNDLE)" "$(DIST)/$(APPNAME).zip"
	@{ \
		echo '# Murmure'; \
		echo; \
		echo '1. Unzip the archive and drag **Murmure.app** to `/Applications`.'; \
		echo '2. If macOS blocks the first launch, Control-click the app, choose Open, and confirm.'; \
		echo '3. Grant Microphone and Accessibility access, then restart Murmure after Accessibility.'; \
		echo '4. Hold the configured push-to-talk key to dictate into the focused app.'; \
		echo '5. To correct a saved dictation, use the pencil Correct action on its history row.'; \
		echo '   Review “Murmure heard” and edit “I meant”; Play original is optional, and Dictate'; \
		echo '   only fills the draft. Remember is on by default, and Save correction is the only'; \
		echo '   action that persists history or a safe contextual local dictionary rule. An'; \
		echo '   interrupted rule stays pending in history and retries safely on the next launch.'; \
		echo; \
		echo 'Murmure stores dictionary entries, settings, transcript history, the dashboard, and'; \
		echo 'captured audio in its Murmure data folder. On this Mac that is'; \
		echo '`/Volumes/Extreme Pro/Murmure Data`; without that drive it uses a local emergency'; \
		echo 'folder and shows the location in Settings. It never removes unrelated drive files.'; \
		echo; \
		echo 'Murmure processes audio, cleanup, dictionary corrections, and history locally on'; \
		echo 'your Mac. No account or hosted API is required for the default workflow.'; \
		echo; \
		echo 'The archive uses a stable Developer ID or local signing identity when available.'; \
		echo 'If neither is available, it falls back to ad-hoc signing and macOS may ask for'; \
		echo 'permissions again after a rebuild. This build'; \
		echo 'is not notarized unless a notarized artifact is explicitly supplied.'; \
	} > "$(DIST)/INSTALL.md"
	@shasum -a 256 "$(DIST)/$(APPNAME).zip" | tee "$(DIST)/$(APPNAME).zip.sha256"
	@echo "wrote $(DIST)/$(APPNAME).zip and $(DIST)/INSTALL.md"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
