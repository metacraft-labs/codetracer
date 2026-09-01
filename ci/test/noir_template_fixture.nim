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
## Usage:  noir_template_fixture <output-directory>
## Prints, one per line:
##   file <relative-path>            for each file written
##   selector <nargo-selector>       for each test the SHARED parser found
##   info <json>                     the constant the bundle ships
##   provenance <sentence>           how that constant was obtained

import std/[os, strutils]

import ../../src/frontend/viewmodel/platform/noir_template
import ../../src/ct_test/frameworks/noir_test_syntax

when isMainModule:
  if paramCount() < 1:
    quit("usage: noir_template_fixture <output-directory>", 2)
  let outDir = paramStr(1)
  let tmpl = noirHelloWorld()

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

  echo "info ", noirTemplateNargoInfoJson.strip()
  echo "provenance ", noirTemplateConstraintProvenance
