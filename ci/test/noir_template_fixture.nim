## Write the bundled Noir template to a directory, and print what the product
## believes about it.
##
## The subject of `ci/test/noir-template-toolchain.sh`. It exists so that gate
## compares the REAL toolchain against the REAL constants rather than against a
## copy of them pasted into a shell script: every value printed here is read
## out of `platform/noir_template.nim` and `ct_test/frameworks/
## noir_test_syntax.nim`, so a template edit changes this program's output
## without anybody touching it.
##
## Usage:  noir_template_fixture <output-directory> [template]
##
## `template` is `starter` (the default, and what every existing caller means)
## or `demo`. It selects through `templateFor`, the product's own mapping,
## rather than by naming a constructor: a gate that reached past `templateFor`
## could pass over a template no route serves, which is the one thing these
## checks exist to prevent.
##
## Prints, one per line:
##   package <name>                  the crate name, i.e. the store key
##   file <relative-path>            for each file written
##   selector <nargo-selector>       for each test the SHARED parser found
##   info <json>                     the counts THIS template ships
##   provenance <sentence>           how those counts were obtained

import std/[os, strutils]

import ../../src/frontend/viewmodel/platform/noir_template
import ../../src/frontend/viewmodel/platform/web_entry
import ../../src/ct_test/frameworks/noir_test_syntax

when isMainModule:
  if paramCount() < 1:
    quit("usage: noir_template_fixture <output-directory> [starter|demo]", 2)
  let outDir = paramStr(1)
  let which = if paramCount() >= 2: paramStr(2) else: "starter"
  let form =
    case which
    of "starter": efBare
    of "demo": efDemo
    else: quit("unknown template '" & which & "'; expected starter or demo", 2)
  let tmpl = templateFor("noir", form)
  if not tmpl.hasFiles:
    quit("templateFor(\"noir\", " & $form & ") has no files", 2)
  echo "package ", tmpl.name

  for file in tmpl.files:
    let target = outDir / file.path
    createDir(target.parentDir)
    writeFile(target, file.content)
    echo "file ", file.path

  var sources: seq[NoirSourceFile] = @[]
  for file in tmpl.files:
    sources.add NoirSourceFile(path: file.path, content: file.content)
  for item in noirCatalogFromSources(sources).items:
    echo "selector ", item.selector

  # OFF THE TEMPLATE, not off the module constants. These two lines named
  # `noirTemplateNargoInfoJson` and `noirTemplateConstraintProvenance`
  # directly, which was indistinguishable from correct while one template
  # existed and reported the hello-world's 17 opcodes for the demo's 478-opcode
  # circuit the moment a second one did — through the gate whose whole job is
  # to catch a drifted count.
  echo "info ", tmpl.nargoInfoJson.strip()
  echo "provenance ", tmpl.constraintProvenance
