## plat36_import_probe.nim — NOT-A-TEST-LANE-FILE. A probe that runs the
## importer over the pinned corpus and prints the census, so the figures that
## go into `corpus/vimrc/manifest.tsv` are MEASURED rather than typed.
import std/[strutils, os, tables]
import ../../keymap/vim_import

const Ids = [
  "v01-vim-mswin", "v02-vim-evim", "v03-vim-defaults", "v04-vim-vimrc-example",
  "v05-vim-gvimrc-example", "v06-vim-less", "v07-vim-dvorak-enable",
  "v08-vim-dvorak-plugin", "v09-vim-swapmouse", "v10-vim-comment",
  "v11-vim-matchit", "v12-vim-justify", "v13-vim-helpcurwin", "v14-nvim-mswin",
  "v15-amix-basic", "v16-amix-extended", "v17-amix-filetypes", "v18-spf13-vimrc",
]

when isMainModule:
  let dir = getCurrentDir() / "src/frontend/viewmodel/tests/corpus/vimrc"
  echo ["id", "map", "trans", "rep", "bind", "unbind", "uniq", "set", "setok",
        "setrep", "reportlen", "vimscript", "plugin", "noop", "noopt",
        "syntax", "div", "macro", "second", "leader"].join("\t")
  var tm, tt, tr, ts, tso, tsr = 0
  for id in Ids:
    let text = readFile(dir / (id & ".vim"))
    let imp = importVimConfig(text)
    let rc = reasonCounts(imp)
    tm += mappingOutcomes(imp); tt += translatedMappingLines(imp)
    tr += reportedMappingLines(imp); ts += optionOutcomes(imp)
    tso += translatedOptionLines(imp); tsr += reportedOptionLines(imp)
    echo [id, $mappingOutcomes(imp), $translatedMappingLines(imp),
          $reportedMappingLines(imp), $boundLines(imp), $unbindLines(imp),
          $uniqueRefusedLines(imp), $optionOutcomes(imp),
          $translatedOptionLines(imp), $reportedOptionLines(imp),
          $imp.report.len, $rc[irVimscript], $rc[irPlugin], $rc[irNoOperation],
          $rc[irNoOption], $rc[irSyntax], $imp.divergences.len,
          $imp.macros.len(), $countMappingLines(text),
          (if imp.mapleaderResolved: imp.mapleader else: "-")].join("\t")
  echo "TOTAL map=", tm, " translated=", tt, " reported=", tr,
       "  settings=", ts, " translated=", tso, " reported=", tsr
