# Murmur build targets.
#
#   make            release .app bundle, same as `make app`
#   make install    build, copy to /Applications and launch
#   make test       SwiftPM tests
#   make bench      benchmark CANDIDATES="bench/candidates/x.json" against the current setup
#   make build      SwiftPM compile only; CONFIG=debug gives a debug build
#   make icon       regenerate Resources/AppIcon.icns
#   make clean      remove all build output
#   make ios-project  generate ios/Murmur.xcodeproj with XcodeGen
#   make ios-build    compile the iPhone app and its keyboard, unsigned
#   make ios-install  signed build, installed on the connected iPhone

EXEC   := Murmur
CONFIG := release

# All generated files go under ~/Library/Caches, which no sync engine watches. A synced folder
# breaks builds in two ways: files change while the compiler reads them, and the provider adds
# extended attributes that codesign refuses.
STAGE    := $(HOME)/Library/Caches/MurmurBuild
SCRATCH  := $(STAGE)/scratch
XCODE_DD := $(STAGE)/xcode

APPNAME  := Murmur.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

XCODE_CONFIG := $(if $(filter debug,$(CONFIG)),Debug,Release)
XCODE_OUT    := $(XCODE_DD)/Build/Products/$(XCODE_CONFIG)
MLX_BUNDLE   := mlx-swift_Cmlx.bundle
DEFAULT_DICTIONARY := Resources/default-dictionary.txt

# Prefer a Developer ID, then Apple Development, then ad-hoc. TCC grants depend on a stable
# signature, and an ad-hoc one differs per build, so ad-hoc means granting Accessibility again
# after every rebuild.
find-identity = $(shell security find-identity -v -p codesigning 2>/dev/null \
                  | grep "$(1)" | head -1 | sed -E 's/.*"(.*)".*/\1/')
SIGN_ID := $(or $(call find-identity,Developer ID Application),$(call find-identity,Apple Development),-)

.PHONY: all build xcbuild test app run install clean icon bench ios-project ios-build ios-install

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

# SwiftPM's command line cannot compile MLX's Metal kernels, so the app goes through xcodebuild,
# which puts them in mlx-swift_Cmlx.bundle. -skipMacroValidation stops xcodebuild asking for
# interactive trust of the tokenizer macro plugin in mlx-swift-lm.
xcbuild:
	xcodebuild build -quiet -scheme $(EXEC) -configuration $(XCODE_CONFIG) \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath "$(XCODE_DD)" \
		-skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO

# Settings tests write throwaway `murmur-tests-<uuid>` domains. Emptying one still leaves an
# empty plist, and cfprefsd writes it back even after a test deletes it, so sweep afterwards.
test:
	swift test --scratch-path "$(SCRATCH)"; status=$$?; rm -f "$(HOME)"/Library/Preferences/murmur-tests-*.plist; exit $$status

# Candidate models against whatever the installed app is set to; see bench/README.md.
PASSES := clean,paced,noisy
bench:
	@test -n "$(CANDIDATES)" || { echo 'usage: make bench CANDIDATES="bench/candidates/x.json" [PASSES=clean,paced,noisy]'; exit 1; }
	uv run bench/bench.py $(CANDIDATES) --passes $(PASSES)

# Run by hand when the artwork changes. It stays out of `app` because it renders ten PNGs.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

# TCC keys Microphone and Accessibility on bundle identity and signature, so only a signed
# bundle gets grants. Every SwiftPM resource bundle is copied, because a generated Bundle.module
# accessor traps at runtime when its bundle is missing from Contents/Resources. The fonts are
# activated by ATSApplicationFontsPath in Info.plist. xattr -cr clears attributes a copied
# binary may carry.
app: xcbuild
	@test -f "$(XCODE_OUT)/$(MLX_BUNDLE)/Contents/Resources/default.metallib" \
		|| { echo "missing MLX metallib in $(XCODE_OUT)/$(MLX_BUNDLE)"; exit 1; }
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(XCODE_OUT)/$(EXEC)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp -R "$(XCODE_OUT)"/*.bundle "$(CONTENTS)/Resources/"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@cp "$(DEFAULT_DICTIONARY)" "$(CONTENTS)/Resources/default-dictionary.txt"
	@mkdir -p "$(CONTENTS)/Resources/Fonts"
	@cp Resources/Fonts/*.ttf Resources/Fonts/OFL-*.txt "$(CONTENTS)/Resources/Fonts/"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

# pkill -x matches this executable name exactly, so it cannot hit another dictation app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

# The destination uses $(APPNAME) alone, because $(BUNDLE) is an absolute staging path.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)" "$(XCODE_DD)"

# The iPhone app and its keyboard extension (ios/project.yml). Output stays under
# ~/Library/Caches like the Mac build. ios-build is unsigned and builds both targets, because
# MurmurPhone embeds MurmurKeyboard; no simulator is involved.
IOS_DD := $(STAGE)/ios

ios-project:
	cd ios && xcodegen generate --quiet
	@# Xcode Cloud does not resolve packages itself; it reads the project's pinned versions.
	mkdir -p ios/Murmur.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
	cp Package.resolved ios/Murmur.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

ios-build: ios-project
	nice -n 10 xcodebuild build -project ios/Murmur.xcodeproj -scheme MurmurPhone \
		-destination 'generic/platform=iOS' -derivedDataPath "$(IOS_DD)" -jobs 4 \
		-skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO

# Signed with the team in ios/Local.xcconfig, then installed on the first physical iPhone
# `devicectl` lists. Needs the phone unlocked and trusted. A Release build: it is what the user
# runs every day, so it has optimisation on and no debug-only assertions or testability.
ios-install: ios-project
	@set -e; \
	mkdir -p "$(STAGE)"; \
	xcrun devicectl list devices --json-output "$(STAGE)/devices.json" >/dev/null; \
	udid="$$(python3 -c 'import json,sys; d=[x for x in json.load(open(sys.argv[1]))["result"]["devices"] if x["hardwareProperties"].get("deviceType")=="iPhone" and x["hardwareProperties"].get("reality")=="physical"]; print(d[0]["hardwareProperties"]["udid"] if d else "")' "$(STAGE)/devices.json")"; \
	test -n "$$udid" || { echo "no physical iPhone found by devicectl"; exit 1; }; \
	echo "installing on $$udid"; \
	nice -n 10 xcodebuild build -project ios/Murmur.xcodeproj -scheme MurmurPhone \
		-destination "id=$$udid" -configuration Release -derivedDataPath "$(IOS_DD)" -jobs 4 \
		-skipMacroValidation -skipPackagePluginValidation -allowProvisioningUpdates; \
	xcrun devicectl device install app --device "$$udid" "$(IOS_DD)/Build/Products/Release-iphoneos/MurmurPhone.app"
