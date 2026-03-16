#!/usr/bin/env bash

set -e

brew install create-dmg

# Remove any leftover DMG from a previous run
rm -f CodeTracer.dmg

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
	"CodeTracer.app"
