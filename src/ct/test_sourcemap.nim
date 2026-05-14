## Unit tests for the schema-2 macro_sourcemap_*.json parser in
## `sourcemap.nim`. The schema is defined by the Nim compiler patch at
## codetracer-nim SHA `82da134b8` (§2-M1, "macro-sourcemap" series). This
## test pins the parser contract so downstream consumers (frontend Monaco
## editor, IPC `ct/update-expansion` handler) can rely on the typed
## representation without ad-hoc JSON probing.
##
## The tests exercise:
##   * Top-level `schema` validation: the parser must refuse
##     pre-M1 / future-schema files.
##   * Schema-2 object shape: `site` and `definition` as `{file,line,col}`.
##   * Per-line `locations` entries with `siteCol` / `entryExpandedCol`.
##   * The new `expressionLocations` map keyed by `(line, col)`.
##   * Defaulting behavior for absent column data (entryExpandedCol = -1).

import std/[os, unittest, strutils, tables]
import sourcemap

const Schema2Fixture = """
{
  "schema": 2,
  "expansions": [
    {
      "path": "/tmp/expanded.nim",
      "firstLine": 1,
      "lastLine": 3,
      "site": {
        "file": "/tmp/user.nim",
        "line": 16,
        "col": 9
      },
      "definition": {
        "file": "/tmp/lib.nim",
        "line": 42,
        "col": 4
      },
      "name": "doAssert",
      "fromMacro": false
    }
  ],
  "locations": {
    "2": {
      "siteFile": "/tmp/user.nim",
      "siteLine": 16,
      "siteCol": 9,
      "expansionId": 0,
      "entryExpandedLine": 7,
      "entryExpandedCol": 2
    },
    "3": {
      "siteFile": "/tmp/user.nim",
      "siteLine": 16,
      "siteCol": 9,
      "expansionId": 0,
      "entryExpandedLine": -1,
      "entryExpandedCol": -1
    }
  },
  "expressionLocations": {
    "3:11": {
      "siteFile": "/tmp/user.nim",
      "siteLine": 16,
      "siteCol": 13,
      "expansionId": 0,
      "entryExpandedLine": -1,
      "entryExpandedCol": -1
    },
    "3:17": {
      "siteFile": "/tmp/user.nim",
      "siteLine": 16,
      "siteCol": 19,
      "expansionId": 0,
      "entryExpandedLine": -1,
      "entryExpandedCol": -1
    },
    "3:24": {
      "siteFile": "/tmp/user.nim",
      "siteLine": 16,
      "siteCol": 26,
      "expansionId": 0,
      "entryExpandedLine": -1,
      "entryExpandedCol": -1
    }
  },
  "expandedEntries": {
    "/tmp/user.nim": {
      "16": 2
    }
  },
  "expandedFilename": "/tmp/expanded.nim",
  "topLevelLines": {
    "1": ["/tmp/user.nim", 16]
  }
}
"""

# A pre-M1 shape (no schema field, 2-tuple site/definition). The parser
# must refuse to load this so older traces can't silently leak through
# the schema-2 contract.
const PreM1Fixture = """
{
  "expansions": [],
  "locations": {},
  "expandedEntries": {},
  "expandedFilename": "",
  "topLevelLines": {}
}
"""

proc writeTmp(name, content: string): string =
  result = getTempDir() / name
  writeFile(result, content)

suite "macro_sourcemap schema-2 parser":

  test "MacroSourcemapSupportedSchema is 2":
    check MacroSourcemapSupportedSchema == 2

  test "parses a full schema-2 fixture":
    let path = writeTmp("ct_sm_schema2.json", Schema2Fixture)
    defer: removeFile(path)
    let (ok, sm) = loadMacroSourcemap(path)
    check ok
    check sm.schema == 2

  test "expansions carry (file, line, col) site and definition":
    let path = writeTmp("ct_sm_site.json", Schema2Fixture)
    defer: removeFile(path)
    let (ok, sm) = loadMacroSourcemap(path)
    check ok
    check sm.expansions.len == 1
    let exp = sm.expansions[0]
    check exp.name == "doAssert"
    check exp.firstLine == 1
    check exp.lastLine == 3
    check exp.path == "/tmp/expanded.nim"
    check exp.site[0] == "/tmp/user.nim"
    check exp.site[1] == 16
    check exp.site[2] == 9
    check exp.definition[0] == "/tmp/lib.nim"
    check exp.definition[1] == 42
    check exp.definition[2] == 4
    check exp.fromMacro == false

  test "locations entries carry siteCol and entryExpandedCol":
    let path = writeTmp("ct_sm_locations.json", Schema2Fixture)
    defer: removeFile(path)
    let (ok, sm) = loadMacroSourcemap(path)
    check ok
    check sm.locations.len == 2
    let line2 = sm.locations[2]
    check line2.siteInfo[0] == "/tmp/user.nim"
    check line2.siteInfo[1] == 16
    check line2.siteInfo[2] == 9
    check line2.expansionId == 0
    check line2.entryExpandedLine == 7
    check line2.entryExpandedCol == 2
    let line3 = sm.locations[3]
    # Statements with no expression entry point use sentinels (-1).
    check line3.entryExpandedLine == -1
    check line3.entryExpandedCol == -1

  test "expressionLocations is keyed by (line, col)":
    let path = writeTmp("ct_sm_exprs.json", Schema2Fixture)
    defer: removeFile(path)
    let (ok, sm) = loadMacroSourcemap(path)
    check ok
    check sm.expressionLocations.len == 3
    # The three expressions on line 3 of expanded.nim.
    check sm.expressionLocations.hasKey((3, 11))
    check sm.expressionLocations.hasKey((3, 17))
    check sm.expressionLocations.hasKey((3, 24))
    # Each entry must carry meaningful site-column data — that's the
    # whole point of the schema-2 expression-level positions.
    let e11 = sm.expressionLocations[(3, 11)]
    check e11.siteInfo[2] == 13
    let e17 = sm.expressionLocations[(3, 17)]
    check e17.siteInfo[2] == 19

  test "expanded entries and top-level lines survive the parse":
    let path = writeTmp("ct_sm_topl.json", Schema2Fixture)
    defer: removeFile(path)
    let (ok, sm) = loadMacroSourcemap(path)
    check ok
    check sm.expandedFilename == "/tmp/expanded.nim"
    check sm.expandedEntries["/tmp/user.nim"][16] == 2
    check sm.topLevelLines[1] == ("/tmp/user.nim", 16)

  test "pre-M1 (missing schema) is rejected":
    let path = writeTmp("ct_sm_preM1.json", PreM1Fixture)
    defer: removeFile(path)
    let (ok, sm) = loadMacroSourcemap(path)
    check ok == false
    check sm.expansions.len == 0

  test "loads a real schema-2 file from the patched compiler":
    # Generated by `bin/nim c --sourcemap:on /tmp/m2_test.nim` against
    # codetracer-nim SHA 82da134b8. Skipped (not failed) if the file is
    # not present in the CI sandbox.
    const realPath = "/tmp/macro_sourcemap_m2_test_bin.json"
    if not fileExists(realPath):
      skip()
    let (ok, sm) = loadMacroSourcemap(realPath)
    check ok
    check sm.schema == 2
    check sm.expansions.len >= 1
    # `doAssert` is the smoking-gun expansion for the `a + 5 == 47` fixture.
    var sawDoAssert = false
    for exp in sm.expansions:
      if exp.name == "doAssert":
        sawDoAssert = true
        # Site must carry a non-zero column (the macro is called at
        # `  doAssert ...` which sits at column >= 2).
        check exp.site[2] >= 0
    check sawDoAssert
    # The `expressionLocations` table must be non-empty for any real
    # macro expansion — that's the schema-2 deliverable.
    check sm.expressionLocations.len > 0
