EXEC     := Murmur
CONFIG   := release

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/MurmurBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/MurmurBuild
APPNAME  := Murmur.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents
DEFAULT_DICTIONARY := Resources/default-dictionary.txt

## The app itself is built with xcodebuild, not `swift build`. S1-mini runs on MLX, whose
## Metal kernels SwiftPM's command line cannot compile; without them MLX finds no metallib
## and fails at the first GPU call. xcodebuild compiles them into mlx-swift_Cmlx.bundle,
## which MLX looks for in Contents/Resources. Same cache directory, for the iCloud reason.
XCODE_CONFIG := $(if $(filter debug,$(CONFIG)),Debug,Release)
XCODE_DD     := $(STAGE)/xcode
XCODE_OUT    := $(XCODE_DD)/Build/Products/$(XCODE_CONFIG)
MLX_BUNDLE   := mlx-swift_Cmlx.bundle

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable Developer ID keeps the identity constant and the grant sticky. Falls back to
## ad-hoc ("-") on a machine without the cert.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)".*/\1/')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build xcbuild test app run install clean icon

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## -skipMacroValidation: mlx-swift-lm's tokenizer macro is a compiler plugin, which
## xcodebuild otherwise refuses to run without an interactive trust prompt.
xcbuild:
	xcodebuild build -quiet -scheme $(EXEC) -configuration $(XCODE_CONFIG) \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath "$(XCODE_DD)" \
		-skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO

test:
	swift test --scratch-path "$(SCRATCH)"

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: xcbuild
	@test -f "$(XCODE_OUT)/$(MLX_BUNDLE)/Contents/Resources/default.metallib" \
		|| { echo "missing MLX metallib in $(XCODE_OUT)/$(MLX_BUNDLE)"; exit 1; }
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(XCODE_OUT)/$(EXEC)" "$(CONTENTS)/MacOS/$(EXEC)"
	@# Every SwiftPM resource bundle, not only MLX's: a package's generated Bundle.module
	@# accessor traps at runtime if its bundle is missing, and it looks in Contents/Resources.
	@cp -R "$(XCODE_OUT)"/*.bundle "$(CONTENTS)/Resources/"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@cp "$(DEFAULT_DICTIONARY)" "$(CONTENTS)/Resources/default-dictionary.txt"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Only ever targets the Murmur executable — never the separate `murmur` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)" "$(XCODE_DD)"
