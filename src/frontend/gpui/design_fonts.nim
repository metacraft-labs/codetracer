## The design system's faces, registered with the GPUI front-end's text system.
##
## The Electron front-end sets interface text in Space Grotesk and code in
## Space Mono (`src/frontend/styles/components/font_family.styl`, fonts from
## `libs/codetracer-design-system`). The GPUI front-end drew the platform's
## fallback (DejaVu Sans / DejaVu Sans Mono) because nothing gave its text
## system those files; a parity review found every label and every code row
## in a different face (2026-10-17). This registers them before launch, and
## `chrome.WindowFontFamily` / `MonoFontFamily` name their families.
##
## WHICH FILES. The `WEB/fonts/*.ttf` that the stylesheet loads carry a broken
## name table — their family is the literal string `false` (measured with
## `fc-scan`) — which CSS never notices because `@font-face` assigns the family
## itself. A text system reads the family from the file, so the OTF builds of
## Space Grotesk (family `Space Grotesk`, five static weights) and Space Mono's
## TTFs (family `Space Mono`) are registered instead: the same outlines.
##
## WHERE. `CODETRACER_FONT_DIR` (a directory holding the files, flat) wins;
## then `<exe dir>/../share/codetracer/fonts`, where a package installs them;
## then the checkout's `libs/codetracer-design-system`. A face that is not
## found is reported on stderr and its family falls back to the platform's,
## exactly as before — the window is never refused for a missing font.

import std/[os, strutils]
import isonim_gpui/window

const
  GroteskFiles* = ["SpaceGrotesk-Light.otf", "SpaceGrotesk-Regular.otf",
                   "SpaceGrotesk-Medium.otf", "SpaceGrotesk-SemiBold.otf",
                   "SpaceGrotesk-Bold.otf"]
  MonoFiles* = ["SpaceMono-Regular.ttf", "SpaceMono-Bold.ttf",
                "SpaceMono-Italic.ttf", "SpaceMono-BoldItalic.ttf"]
  checkoutFonts = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
                  "libs" / "codetracer-design-system" / "SpaceGrotesk_Complete" / "Fonts"

proc fontCandidates*(file: string): seq[string] =
  ## Where `file` is looked for, in order.
  let dir = getEnv("CODETRACER_FONT_DIR")
  if dir.len > 0: result.add dir / file
  result.add getAppDir().parentDir / "share" / "codetracer" / "fonts" / file
  let sub = if file.startsWith("SpaceMono"): "Space_Mono" else: "SpaceGrotesk_OTF"
  result.add checkoutFonts / sub / file

proc registerDesignFonts*(): int =
  ## Register every design-system face that can be found; returns how many.
  for file in @GroteskFiles & @MonoFiles:
    var done = false
    for path in fontCandidates(file):
      if fileExists(path) and addFontFile(path):
        done = true
        inc result
        break
    if not done:
      stderr.writeLine "codetracer-gpui: design font " & file &
        " not found (looked in " & fontCandidates(file).join(", ") &
        "); its family falls back to the platform's face"
