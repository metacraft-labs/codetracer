## vimrc_corpus.nim — PLAT-36's pinned `.vimrc` corpus, reachable from a suite
## on every backend this directory is compiled by.
##
## NOT-A-TEST-LANE-FILE: the corpus's loader, not a suite. The assertions are in
## `../unit/test_editor_vim_import.nim` and
## `../unit/test_editor_vim_import_differential.nim`.
##
## `staticRead`, NEVER a runtime `readFile`
## ========================================
## PLAT-24's `unicode_corpus.nim` states the reason and it is unchanged here:
## `std/os`'s `readFile` DOES NOT EXIST on the JS backend, and this directory is
## compiled by three lanes — `vm-unit` (C), `vm-unit-js` (node) and
## `vm-unit-wasm`. The second reason is louder than the first: a missing corpus
## document becomes a COMPILE error naming the path, where a loader returning
## "" for a file that has moved turns every law quantified over the corpus into
## a law about the empty string, and those pass.
##
## The manifest is read the same way, so the ORACLE is bytes rather than a
## transcription. `manifestRows()` parses it at run time on whichever backend is
## running; nothing in the suites produces an expected value from the importer.

import std/strutils

type
  VimrcDoc* = object
    id*: string
    text*: string

  VimrcFileClass* = enum
    ## The class of a FILE, derived from (translated, reported). Four, not
    ## three, and the fourth is the one this campaign keeps losing: a file with
    ## no mapping line at all is EMPTY, which is a different answer from *"I
    ## could not read any of them"*.
    vfcEmpty = "empty"
    vfcTranslated = "translated"
    vfcReported = "reported"
    vfcMixed = "mixed"

  VimrcManifestRow* = object
    ## One row of `vimrc/manifest.tsv`, parsed at run time. `mapLines`,
    ## `settings`, `rPlugin` and `leader` are produced by
    ## `vimrc-corpus-census.py` — a parser in another language sharing no code
    ## with `vim_import.nim` — and are the corpus's INDEPENDENT half. The rest
    ## are pinned measurements, which the manifest's own header says in so many
    ## words.
    id*, audit*, leader*: string
    class*: VimrcFileClass
    mapLines*, settings*, translated*, reported*, bound*, unbound*: int
    uniqueRefused*, optTranslated*, optReported*: int
    rVimscript*, rPlugin*, rNoOperation*, rNoOption*, rSyntax*: int
    divergences*: int

const
  VimrcCorpusSize* = 18
    ## The milestone's *"eighteen real, published Vim configurations"*. It is a
    ## const rather than `CorpusDocs.len` so that a document silently dropped
    ## from the array below fails an equality instead of shrinking a sweep's
    ## multiplier — §10.4's third rule, applied to the corpus rather than to
    ## the floor.

  CorpusDocs* = [
    VimrcDoc(id: "v01-vim-mswin", text: staticRead("vimrc/v01-vim-mswin.vim")),
    VimrcDoc(id: "v02-vim-evim", text: staticRead("vimrc/v02-vim-evim.vim")),
    VimrcDoc(id: "v03-vim-defaults",
             text: staticRead("vimrc/v03-vim-defaults.vim")),
    VimrcDoc(id: "v04-vim-vimrc-example",
             text: staticRead("vimrc/v04-vim-vimrc-example.vim")),
    VimrcDoc(id: "v05-vim-gvimrc-example",
             text: staticRead("vimrc/v05-vim-gvimrc-example.vim")),
    VimrcDoc(id: "v06-vim-less", text: staticRead("vimrc/v06-vim-less.vim")),
    VimrcDoc(id: "v07-vim-dvorak-enable",
             text: staticRead("vimrc/v07-vim-dvorak-enable.vim")),
    VimrcDoc(id: "v08-vim-dvorak-plugin",
             text: staticRead("vimrc/v08-vim-dvorak-plugin.vim")),
    VimrcDoc(id: "v09-vim-swapmouse",
             text: staticRead("vimrc/v09-vim-swapmouse.vim")),
    VimrcDoc(id: "v10-vim-comment",
             text: staticRead("vimrc/v10-vim-comment.vim")),
    VimrcDoc(id: "v11-vim-matchit",
             text: staticRead("vimrc/v11-vim-matchit.vim")),
    VimrcDoc(id: "v12-vim-justify",
             text: staticRead("vimrc/v12-vim-justify.vim")),
    VimrcDoc(id: "v13-vim-helpcurwin",
             text: staticRead("vimrc/v13-vim-helpcurwin.vim")),
    VimrcDoc(id: "v14-nvim-mswin", text: staticRead("vimrc/v14-nvim-mswin.vim")),
    VimrcDoc(id: "v15-amix-basic", text: staticRead("vimrc/v15-amix-basic.vim")),
    VimrcDoc(id: "v16-amix-extended",
             text: staticRead("vimrc/v16-amix-extended.vim")),
    VimrcDoc(id: "v17-amix-filetypes",
             text: staticRead("vimrc/v17-amix-filetypes.vim")),
    VimrcDoc(id: "v18-spf13-vimrc",
             text: staticRead("vimrc/v18-spf13-vimrc.vim")),
  ]

  ManifestSource* = staticRead("vimrc/manifest.tsv")
  ProvenanceSource* = staticRead("vimrc/provenance.tsv")

proc classOf*(s: string): VimrcFileClass =
  for c in VimrcFileClass:
    if $c == s: return c
  raise newException(ValueError, "manifest names an unknown file class: " & s)

proc manifestRows*(): seq[VimrcManifestRow] =
  ## Parse `manifest.tsv`. **A ROW WITH THE WRONG NUMBER OF FIELDS RAISES**
  ## rather than being skipped: a parser that silently drops a row satisfies
  ## every check written over what it read (§4), and the suite's own case count
  ## would shrink with it.
  result = @[]
  for raw in ManifestSource.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let f = raw.split('\t')
    if f.len != 19:
      raise newException(ValueError,
        "manifest.tsv row has " & $f.len & " fields, expected 19: " & raw)
    if f[0] == "id": continue
    result.add VimrcManifestRow(
      id: f[0], class: classOf(f[1]), mapLines: parseInt(f[2]),
      settings: parseInt(f[3]), translated: parseInt(f[4]),
      reported: parseInt(f[5]), bound: parseInt(f[6]),
      unbound: parseInt(f[7]), uniqueRefused: parseInt(f[8]),
      optTranslated: parseInt(f[9]), optReported: parseInt(f[10]),
      rVimscript: parseInt(f[11]), rPlugin: parseInt(f[12]),
      rNoOperation: parseInt(f[13]), rNoOption: parseInt(f[14]),
      rSyntax: parseInt(f[15]), divergences: parseInt(f[16]),
      audit: f[17], leader: f[18])

proc provenanceRows*(): seq[seq[string]] =
  ## `(id, repo, commit, path, licence, sha256)` per corpus document.
  result = @[]
  for raw in ProvenanceSource.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let f = raw.split('\t')
    if f.len != 6:
      raise newException(ValueError,
        "provenance.tsv row has " & $f.len & " fields, expected 6: " & raw)
    result.add f

proc docNamed*(id: string): string =
  for d in CorpusDocs:
    if d.id == id: return d.text
  raise newException(ValueError, "no corpus document named " & id)
