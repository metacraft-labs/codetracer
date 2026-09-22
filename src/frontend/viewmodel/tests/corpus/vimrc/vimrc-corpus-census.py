#!/usr/bin/env python3
"""vimrc-corpus-census.py — the corpus's DENOMINATOR, read by a second parser.

Verification-Harness-Traps §30a: *"if the importer's oracle shares a parser
with the importer, it measures nothing."* The partition law
`translated + reported == total mapping lines` is worth nothing if `total` is
computed from the same walk that produced `translated` and `reported` — that is
§22's *"a cross-check whose two sides are computed from the same expression"*.

So the denominator has THREE independent producers, and the suite asserts all
three agree:

  1. `vim_import.importVimConfig`'s outcome list, filtered to `lkMapping`;
  2. `vim_import.countMappingLines`, a second pass over the raw text inside the
     same module that never looks at an outcome;
  3. **this file**, in another language, sharing no code with either, whose
     answer is committed as bytes in `manifest.tsv`.

WHAT THIS CENSUS DOES AND DOES NOT CLAIM TO DECIDE
==================================================
It decides what a SECOND READING OF THE DOCUMENT can decide without knowing
anything about this editor's vocabulary:

  * `mapLines`   — how many lines are one of §6.1's 22 map-family commands.
  * `settings`   — how many option words the file's `set` lines carry.
  * `plugRefs`   — how many mapping lines name a `<Plug>` binding.
  * `leader`     — the unconditional `mapleader` literal, or `-`.

It does NOT decide translated-versus-reported, because deciding that requires
walking the 434-row Vim keymap, and a Python re-derivation of that table would
be §30a's *"a whole re-derived module"* — a correct copy is invisible to every
assertion and an incorrect one grades the importer against a second bug.

Those columns of `manifest.tsv` are therefore PINNED MEASUREMENTS with an
`audit` column saying so per row, in PLAT-24's manner (*"`oracle: -` where
there is none, which is a fact the manifest states rather than hides"*).
TWELVE of the eighteen rows are additionally HAND-AUDITED — the files with
nine or fewer mapping lines, plus the four larger ones that are uniform in
shape and were checked structurally, line count by line count:
`swapmouse` (20 mouse remaps), `comment` (16 `<Plug>` rows), `matchit`
(26 `<Plug>` rows and 13 `[nxo]unmap`s) and `dvorak/enable` (70
`inoremap x y`). That is 166 of the 604 mapping lines checked by something
other than the program under test.

The authority for this is `manifest.tsv`'s `audit` column, not this
paragraph: count the rows reading `hand-audited` and sum their `mapLines`.

    python3 vimrc-corpus-census.py            # print the census
    python3 vimrc-corpus-census.py --check    # compare against manifest.tsv
"""

from __future__ import annotations

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# §6.1's 22 spellings and Vim's documented minimal abbreviation for each
# (`:help :map`, `:help :nnoremap`, …). Written from the Vim documentation, not
# from the Nim table — that is the point of this file.
FAMILIES = {
    "map": "map", "nmap": "nm", "vmap": "vm", "xmap": "xm", "smap": "sm",
    "omap": "om", "imap": "im", "cmap": "cm", "lmap": "lm",
    "noremap": "no", "nnoremap": "nn", "vnoremap": "vn", "xnoremap": "xn",
    "snoremap": "snor", "onoremap": "ono", "inoremap": "ino",
    "cnoremap": "cno", "lnoremap": "ln",
    "map!": "map!", "noremap!": "no!",
    "unmap": "unm", "mapclear": "mapc",
}

# `nunmap`, `vunmap`, …, `nmapclear`, … are mode-prefixed spellings of the last
# two. They are mapping lines; classifying them as ordinary Vimscript would
# lose them, which is the defect the partition law exists against.
PREFIXED = re.compile(r"^[nvxsoicl](unm(a(p)?)?|mapc(l(e(a(r)?)?)?)?)!?$")

OPTIONS = ["tabstop", "shiftwidth", "expandtab", "wrap", "number",
           "relativenumber", "ignorecase", "smartcase", "timeoutlen",
           "scrolloff"]

SET_HEADS = {"set", "se", "setlocal", "setl", "setglobal", "setg"}

IDS = [
    "v01-vim-mswin", "v02-vim-evim", "v03-vim-defaults",
    "v04-vim-vimrc-example", "v05-vim-gvimrc-example", "v06-vim-less",
    "v07-vim-dvorak-enable", "v08-vim-dvorak-plugin", "v09-vim-swapmouse",
    "v10-vim-comment", "v11-vim-matchit", "v12-vim-justify",
    "v13-vim-helpcurwin", "v14-nvim-mswin", "v15-amix-basic",
    "v16-amix-extended", "v17-amix-filetypes", "v18-spf13-vimrc",
]


def is_family(word: str) -> bool:
    if word in FAMILIES:
        return True
    for full, minimal in FAMILIES.items():
        if len(word) >= len(minimal) and full.startswith(word) \
                and word.startswith(minimal):
            return True
    return bool(PREFIXED.match(word))


def logical_lines(text: str):
    """Vim's line continuation: a line starting with `\\` joins the one before."""
    out = []
    for raw in text.split("\n"):
        s = raw.strip()
        if s.startswith("\\") and out:
            out[-1] = out[-1] + s[1:]
        else:
            out.append(raw)
    return out


def strip_set_comment(s: str) -> str:
    for i in range(1, len(s)):
        if s[i] == '"' and s[i - 1] in " \t":
            return s[:i].strip()
    return s


def census(text: str) -> dict:
    vim9 = any(l.strip().startswith("vim9script") for l in text.split("\n"))
    mapl, settings, plug = 0, 0, 0
    leader = "-"
    for raw in text.split("\n"):
        if raw[:1] in (" ", "\t") or not raw:
            continue
        s = raw.strip()
        if not (s.startswith("let mapleader") or s.startswith("let g:mapleader")):
            continue
        if "=" not in s:
            continue
        rhs = s.split("=", 1)[1].strip()
        if len(rhs) >= 2 and rhs[0] in "\"'" and rhs[-1] == rhs[0]:
            lit = rhs[1:-1]
            if rhs[0] == '"':
                lit = lit.replace("\\\\", "\\")
            if lit:
                leader = lit
    for raw in logical_lines(text):
        s = raw.strip()
        if not s:
            continue
        if s[0] == '"' or (vim9 and s[0] == "#"):
            continue
        if s[0] == ":":
            s = s[1:].strip()
        fields = s.split()
        if not fields:
            continue
        head = fields[0]
        if head in SET_HEADS:
            rest = strip_set_comment(s[len(head):].strip())
            settings += len(rest.split())
            continue
        if is_family(head):
            mapl += 1
            if "<plug>" in s.lower():
                plug += 1
    return {"mapLines": mapl, "settings": settings, "plugRefs": plug,
            "leader": leader}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare against the committed manifest.tsv")
    args = ap.parse_args()

    rows = {}
    for cid in IDS:
        with open(os.path.join(HERE, cid + ".vim"), encoding="utf-8",
                  errors="replace") as fh:
            rows[cid] = census(fh.read())

    total_map = sum(r["mapLines"] for r in rows.values())
    total_set = sum(r["settings"] for r in rows.values())
    print("id\tmapLines\tsettings\tplugRefs\tleader")
    for cid in IDS:
        r = rows[cid]
        print(f"{cid}\t{r['mapLines']}\t{r['settings']}\t{r['plugRefs']}\t"
              f"{r['leader']}")
    print(f"TOTAL\t{total_map}\t{total_set}")

    if not args.check:
        return 0

    bad = 0
    seen = 0
    with open(os.path.join(HERE, "manifest.tsv"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            f = line.rstrip("\n").split("\t")
            cid = f[0]
            if cid == "id":
                continue
            seen += 1
            if cid not in rows:
                print(f"FAIL: manifest names {cid}, which this census has no row for")
                bad += 1
                continue
            want = {"mapLines": int(f[2]), "settings": int(f[3]),
                    "plugRefs": int(f[12]), "leader": f[18]}
            for key in want:
                if rows[cid][key] != want[key]:
                    print(f"FAIL: {cid}.{key}: manifest {want[key]}, "
                          f"census {rows[cid][key]}")
                    bad += 1
    if seen != len(IDS):
        print(f"FAIL: manifest holds {seen} rows, census holds {len(IDS)}")
        bad += 1
    if bad:
        print(f"FAIL: {bad} disagreement(s). The MANIFEST is what gets fixed, "
              f"or the corpus grammar is ambiguous — neither parser is "
              f"adjusted to match the other.")
        return 1
    print(f"OK: {seen} rows, four independently-derived columns each, agree "
          f"with manifest.tsv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
