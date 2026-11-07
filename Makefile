# Murmur build targets.
#
#   make            release .app bundle, same as `make app`
#   make install    build, copy to /Applications and launch
#   make test       SwiftPM tests
#   make build      SwiftPM compile only; CONFIG=debug gives a debug build
#   make icon       regenerate Resources/AppIcon.icns
#   make clean      remove all build output

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

.PHONY: all build xcbuild test app run install clean icon

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

test:
	swift test --scratch-path "$(SCRATCH)"

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
