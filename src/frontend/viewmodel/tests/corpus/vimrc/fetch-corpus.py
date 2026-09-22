#!/usr/bin/env python3
"""fetch-corpus.py — PLAT-36's pinned `.vimrc` corpus, re-fetched from source.

Editing-Operations-And-Keymaps.md §6 asks for *"a pinned corpus of real,
published Vim configurations, named in the repo with their source and
revision, so the coverage figure is reproducible and the denominator cannot
move between runs"*.

THE BYTES ARE COMMITTED; THIS SCRIPT IS HOW A READER RE-TAKES THEM.
====================================================================
The suites `staticRead` the committed files, exactly as PLAT-24's Unicode
corpus is read, so a corpus document that moved is a COMPILE error naming the
path rather than an empty string that satisfies every law quantified over it.
This script exists so the provenance in `provenance.tsv` is a claim somebody
can check rather than believe: it re-downloads every row at its pinned commit
and compares the SHA-256 against the committed file.

    python3 fetch-corpus.py --verify     # re-download and compare; the usual use
    python3 fetch-corpus.py --write      # re-download and overwrite

`--verify` is the interesting one and it needs the network; it is NOT part of
any lane, because a gate that depends on github.com is a gate that reddens when
github.com is slow. The lane's reproducibility comes from the committed bytes
and from `manifest.tsv`'s digests, which are checked with no network at all.

WHY THESE EIGHTEEN, STATED SO IT CAN BE DISAGREED WITH
=====================================================
They are not eighteen individuals' personal dotfiles, and saying so is the
point of this paragraph. They are eighteen real, published Vim script files
that a user sources as configuration, drawn from four upstreams with four
clear licences:

  * `vim/vim`'s own distributed runtime — `mswin.vim`, `evim.vim`,
    `defaults.vim`, the two example vimrcs, `macros/less.vim` and six of the
    `pack/dist/opt` plugins. These are the configurations Vim itself ships and
    tells users to `:source`; `mswin.vim` in particular is the single most
    widely sourced Vim configuration in existence.
  * `neovim/neovim`'s `runtime/scripts/mswin.vim`, which has DIVERGED from
    Vim's and is in the corpus for that reason rather than for its size.
  * `amix/vimrc` (MIT, ~32k stars) — three files of a personal configuration
    published as a distribution.
  * `spf13/spf13-vim` (Apache-2.0, ~15k stars) — a 1251-line personal
    `.vimrc`, the largest and messiest document in the set.

The alternative — eighteen dotfiles repositories scraped by popularity — was
refused for two reasons that are facts rather than preferences: most carry no
licence at all, so redistributing them here would be a guess; and their
*distribution* is narrower than this set's, not wider, because they are
overwhelmingly the same `<leader>`-and-`:command<CR>` shape. This set spans
pure key-to-key remaps (`dvorak/enable.vim`, 70 lines with no Vimscript at
all), pure `<Plug>` indirection (`comment.vim`, 16 lines of which none is
translatable), mouse events, `set`-only files with no mapping at all, and two
large personal configurations.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# id, repo, commit, path-in-repo, licence
ROWS = [
    ("v01-vim-mswin", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/mswin.vim", "Vim"),
    ("v02-vim-evim", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/evim.vim", "Vim"),
    ("v03-vim-defaults", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/defaults.vim", "Vim"),
    ("v04-vim-vimrc-example", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/vimrc_example.vim", "Vim"),
    ("v05-vim-gvimrc-example", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/gvimrc_example.vim", "Vim"),
    ("v06-vim-less", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/macros/less.vim", "Vim"),
    ("v07-vim-dvorak-enable", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/pack/dist/opt/dvorak/dvorak/enable.vim", "Vim"),
    ("v08-vim-dvorak-plugin", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/pack/dist/opt/dvorak/plugin/dvorak.vim", "Vim"),
    ("v09-vim-swapmouse", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/pack/dist/opt/swapmouse/plugin/swapmouse.vim", "Vim"),
    ("v10-vim-comment", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/pack/dist/opt/comment/plugin/comment.vim", "Vim"),
    ("v11-vim-matchit", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/pack/dist/opt/matchit/plugin/matchit.vim", "Vim"),
    ("v12-vim-justify", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/pack/dist/opt/justify/plugin/justify.vim", "Vim"),
    ("v13-vim-helpcurwin", "vim/vim", "12c69acc0a1f1530dc0f0618c763bd9c07b7b6b3",
     "runtime/pack/dist/opt/helpcurwin/plugin/helpcurwin.vim", "Vim"),
    ("v14-nvim-mswin", "neovim/neovim", "adbe0493b3f5e72f4caf672621e5fdffc9b327a6",
     "runtime/scripts/mswin.vim", "Vim (Neovim runtime)"),
    ("v15-amix-basic", "amix/vimrc", "46294d589d15d2e7308cf76c58f2df49bbec31e8",
     "vimrcs/basic.vim", "MIT"),
    ("v16-amix-extended", "amix/vimrc", "46294d589d15d2e7308cf76c58f2df49bbec31e8",
     "vimrcs/extended.vim", "MIT"),
    ("v17-amix-filetypes", "amix/vimrc", "46294d589d15d2e7308cf76c58f2df49bbec31e8",
     "vimrcs/filetypes.vim", "MIT"),
    ("v18-spf13-vimrc", "spf13/spf13-vim", "e29767450ad849423e6df5ca2d77c36e15cead50",
     ".vimrc", "Apache-2.0"),
]

CORPUS_SIZE = 18


def url_of(repo: str, commit: str, path: str) -> str:
    return f"https://raw.githubusercontent.com/{repo}/{commit}/{path}"


def check_digests() -> int:
    """The OFFLINE half: the committed bytes against `provenance.tsv`.

    `--verify` needs github.com and therefore cannot be a gate. This can, and
    it is what makes "the denominator cannot move between runs" checkable on a
    machine with no network: a corpus file edited in place changes its digest.
    """
    want = {}
    with open(os.path.join(HERE, "provenance.tsv"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            f = line.rstrip("\n").split("\t")
            want[f[0]] = f[5]
    bad = 0
    for cid, repo, commit, path, lic in ROWS:
        if cid not in want:
            print(f"FAIL: {cid} is in ROWS and not in provenance.tsv")
            bad += 1
            continue
        with open(os.path.join(HERE, cid + ".vim"), "rb") as fh:
            have = hashlib.sha256(fh.read()).hexdigest()
        if len(want[cid]) != 64:
            print(f"FAIL: {cid}'s recorded digest is {len(want[cid])} "
                  f"characters, not 64 — a truncated digest is a digest that "
                  f"was typed rather than taken")
            bad += 1
        elif have != want[cid]:
            print(f"FAIL: {cid}.vim is {have[:16]}…, provenance says "
                  f"{want[cid][:16]}…")
            bad += 1
    extra = set(want) - {r[0] for r in ROWS}
    if extra:
        print(f"FAIL: provenance.tsv names rows ROWS does not: {sorted(extra)}")
        bad += 1
    if bad:
        return 1
    print(f"OK: {len(ROWS)} corpus files match their recorded SHA-256")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true",
                    help="overwrite the committed files with what was fetched")
    ap.add_argument("--verify", action="store_true",
                    help="fetch and compare against the committed files")
    ap.add_argument("--digests", action="store_true",
                    help="compare the committed files against provenance.tsv, "
                         "with no network at all")
    args = ap.parse_args()
    if not (args.write or args.verify or args.digests):
        ap.error("pass --digests, --verify or --write")

    if args.digests:
        return check_digests()

    if len(ROWS) != CORPUS_SIZE:
        print(f"FAIL: ROWS holds {len(ROWS)} rows, expected {CORPUS_SIZE}")
        return 1
    if len({r[0] for r in ROWS}) != CORPUS_SIZE:
        print("FAIL: duplicate corpus id")
        return 1

    bad = 0
    for cid, repo, commit, path, lic in ROWS:
        dest = os.path.join(HERE, cid + ".vim")
        data = urllib.request.urlopen(url_of(repo, commit, path), timeout=60).read()
        digest = hashlib.sha256(data).hexdigest()
        if args.write:
            with open(dest, "wb") as fh:
                fh.write(data)
            print(f"wrote {cid}.vim  {digest[:16]}  {lic}")
            continue
        if not os.path.exists(dest):
            print(f"MISSING {cid}.vim")
            bad += 1
            continue
        with open(dest, "rb") as fh:
            have = hashlib.sha256(fh.read()).hexdigest()
        if have != digest:
            print(f"DIFFERS {cid}.vim  committed={have[:16]} upstream={digest[:16]}")
            bad += 1
        else:
            print(f"ok      {cid}.vim  {digest[:16]}")
    if bad:
        print(f"FAIL: {bad} of {CORPUS_SIZE} rows do not match their pinned source")
        return 1
    print(f"OK: {CORPUS_SIZE} of {CORPUS_SIZE} rows match their pinned source")
    return 0


if __name__ == "__main__":
    sys.exit(main())
