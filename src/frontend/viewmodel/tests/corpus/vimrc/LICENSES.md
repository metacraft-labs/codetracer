# Licences of the vendored corpus

The eighteen files beside this one are **unmodified** upstream Vim scripts,
fetched at the commits `provenance.tsv` pins and verified by SHA-256
(`fetch-corpus.py --digests`, and `--verify` to re-fetch). They are test
inputs. No CodeTracer code derives from them.

`provenance.tsv` names each file's upstream, commit, path and licence. This
file carries the notices those licences require to travel with the bytes.

## MIT — `v15-amix-basic`, `v16-amix-extended`, `v17-amix-filetypes`

From [amix/vimrc](https://github.com/amix/vimrc) at `46294d58`. MIT requires
its copyright and permission notice to accompany substantial portions of the
software, so it is reproduced in full:

```
The MIT License (MIT)

Copyright (c) 2016 Amir Salihefendic

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Apache-2.0 — `v18-spf13-vimrc`

From [spf13/spf13-vim](https://github.com/spf13/spf13-vim) at `e2976745`. The
file carries its own Apache-2.0 header inline, which is the notice the licence
asks for; the full text is at <https://www.apache.org/licenses/LICENSE-2.0>.

## Vim licence — the fourteen `v01`–`v14` files

From [vim/vim](https://github.com/vim/vim) at `12c69acc` and
[neovim/neovim](https://github.com/neovim/neovim) at `adbe0493`, under the Vim
licence (`:help license`, Vim 9.1). It is **charityware, not a permissive
licence**: it permits unrestricted distribution of *unmodified* copies, and
attaches conditions to distributing **modified** versions.

These copies are unmodified and the pinned SHA-256s are what demonstrates it.
Anyone changing a byte of them takes on those conditions — so do not edit them
in place. Replace a file by re-pinning it in `provenance.tsv` and re-fetching.
