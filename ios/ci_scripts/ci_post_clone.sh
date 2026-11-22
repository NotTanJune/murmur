#!/bin/sh
# Xcode Cloud runs this after cloning, before it resolves packages and builds the MurmurPhone
# scheme from the checked-in ios/Murmur.xcodeproj.
set -eu

# The signing team and build number live in ios/Local.xcconfig, which git ignores (it holds the
# local team on the Mac). Here both come from Xcode Cloud: its team, and a build number that
# rises with every cloud build so TestFlight accepts each upload.
cat > "$CI_PRIMARY_REPOSITORY_PATH/ios/Local.xcconfig" <<XCCONFIG
DEVELOPMENT_TEAM = ${CI_TEAM_ID}
CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER}
XCCONFIG

# The package graph includes Swift macros and plugins (through FluidAudio and MLX). Locally
# `make` passes -skipMacroValidation; Xcode Cloud reads these defaults instead.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
