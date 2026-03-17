#!/usr/bin/env bash

set -e

brew install create-dmg

# Remove any leftover DMG from a previous run
rm -f CodeTracer.dmg

# create-dmg copies the *contents* of the source directory into the DMG
# volume.  If we pass CodeTracer.app directly, the volume root ends up
# with Contents/ at the top level instead of CodeTracer.app/Contents/.
# Use a staging directory so that the .app bundle is preserved inside
# the DMG — this is the standard macOS convention and what users and CI
# tools expect when extracting.
DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT
cp -R CodeTracer.app "$DMG_STAGING/"

create-dmg \
	--volname "CodeTracer" \
	--background "dmg_background.png" \
	--window-pos 200 120 \
	--window-size 600 400 \
	--icon-size 100 \
	--icon "CodeTracer.app" 150 200 \
	--app-drop-link 450 200 \
	--sandbox-safe \
	--hdiutil-retries 15 \
	"CodeTracer.dmg" \
	"$DMG_STAGING"
