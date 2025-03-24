#!/usr/bin/env bash

brew install create-dmg

create-dmg \
  --volname "CodeTracer" \
  --background "dmg_background.png" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "CodeTracer.app" 150 190 \
  --app-drop-link 450 185 \
  "CodeTracer.dmg" \
  "CodeTracer.app"

