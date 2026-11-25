#!/usr/bin/env python3
"""css-url-resolution-guard.py — every url() in a shipped stylesheet names a file that exists.

WHY THIS EXISTS
---------------
A ``url()`` whose file is missing compiles clean and fails silently: the
browser requests it, gets nothing, and paints no icon, no background, no face.
Three such references shipped in the theme stylesheets with nothing noticing:

  * ``#jump-before-image`` / ``#jump-after-image`` named
    ``jump-{before,after}_16_dark.svg``, which never existed (and no element
    carries either id, so the rules were dead as well);
  * the FontAwesome ``@font-face`` listed a ``fontawesome-webfont.ttf``
    fallback beside the stylesheet, where no such file has ever been.

They were found by a renderer (zgui) that reports the resources it cannot
load. This guard makes that report a CI verdict instead of a lucky catch.

HOW A URL IS RESOLVED
---------------------
The runner (``css-url-resolution.sh``) compiles each shipped entry point with
``ci/lib/compile-shipped-stylesheets.sh``. Each compiled sheet ships at
``src/build-<type>-repro/frontend/styles/<name>.css`` (``repro.nim``), so a
relative url resolves against that directory, exactly as the browser resolves
it against the sheet's own URL. The build type does not matter: every variant
dir sits at the same depth.

The build directory itself need not exist. A path that lands under the build
dir's ``public/`` is looked up in ``src/public/``, which the build copies there
(``frontend-public-resources``, a ``preserveTree`` of ``PublicResourceRoot``).
A path that lands anywhere else inside the build dir names a file nothing puts
there, and is reported. Paths outside the build dir (``libs/...``,
``src/public/...`` reached by an extra ``../``) are checked where they are.

``data:`` URLs, fragment-only references (``url(#clip)``) and absolute
``http(s):`` URLs are not files and are skipped; the count of each is printed.
A query or fragment after a file path (``font.woff?v=4.7.0#x``) is dropped
before the lookup.

INSTRUMENT CHECKS
-----------------
An empty directory, a directory of empty stylesheets, or a set of sheets with
no ``url()`` at all is a failure: a guard that resolved nothing has checked
nothing. ``--self-test`` runs the resolver over planted fixtures and fails
unless each verdict is the expected one.

WHAT IT DOES NOT CATCH
----------------------
URLs a script builds at run time, and third-party stylesheets copied verbatim
under ``src/public/third_party`` (they are not compiled by this build).
"""

import argparse
import os
import posixpath
import re
import sys
import tempfile
from typing import List, NamedTuple, Optional, Tuple

COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
URL_RE = re.compile(r"url\(\s*(?:\"([^\"]*)\"|'([^']*)'|([^)\s]*))\s*\)", re.I)
# Where a compiled sheet ships, relative to the repo root. Any build type works:
# every `src/build-<type>-repro` sits at the same depth.
SHEET_DIR = "src/build-debug-repro/frontend/styles"
BUILD_DIR = "src/build-debug-repro"
PUBLIC_SOURCE = "src/public"


class Finding(NamedTuple):
    stylesheet: str
    line: int
    url: str
    looked_for: str


class Counts(NamedTuple):
    files: int
    data: int
    fragment: int
    remote: int


def strip_comments(text: str) -> str:
    """Blank out comments, keeping newlines so line numbers stay right."""
    return COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def source_path(repo_root: str, url: str) -> Optional[str]:
    """The repo path a relative file url resolves to, or None if it lands in
    the build dir somewhere nothing puts files."""
    path = re.split(r"[?#]", url, maxsplit=1)[0]
    resolved = posixpath.normpath(posixpath.join(SHEET_DIR, path))
    build_public = BUILD_DIR + "/public/"
    if resolved.startswith(build_public):
        resolved = PUBLIC_SOURCE + "/" + resolved[len(build_public):]
    elif resolved == BUILD_DIR or resolved.startswith(BUILD_DIR + "/"):
        return None
    return os.path.join(repo_root, *resolved.split("/"))


def scan_text(repo_root: str, name: str, text: str) -> Tuple[Counts, List[Finding]]:
    text = strip_comments(text)
    findings: List[Finding] = []
    files = data = fragment = remote = 0
    for match in URL_RE.finditer(text):
        url = next(g for g in match.groups() if g is not None).strip()
        lower = url.lower()
        if lower.startswith("data:"):
            data += 1
            continue
        if url.startswith("#"):
            fragment += 1
            continue
        if re.match(r"^[a-z][a-z0-9+.-]*:", lower) or url.startswith("//"):
            remote += 1
            continue
        files += 1
        target = source_path(repo_root, url)
        if target is None or not os.path.isfile(target):
            line = text.count("\n", 0, match.start()) + 1
            shown = "(inside the build dir, where nothing is copied)" if target is None \
                else os.path.relpath(target, repo_root)
            findings.append(Finding(name, line, url, shown))
    return Counts(files, data, fragment, remote), findings


def scan_dir(repo_root: str, css_dir: str) -> Tuple[List[str], Counts, List[Finding]]:
    problems: List[str] = []
    names = sorted(n for n in os.listdir(css_dir) if n.endswith(".css")) if os.path.isdir(css_dir) else []
    if not names:
        return [f"no stylesheets in {css_dir}: nothing was checked"], Counts(0, 0, 0, 0), []
    totals = [0, 0, 0, 0]
    findings: List[Finding] = []
    nonempty = 0
    for name in names:
        with open(os.path.join(css_dir, name), encoding="utf-8") as handle:
            text = handle.read()
        if text.strip():
            nonempty += 1
        counts, found = scan_text(repo_root, name, text)
        totals = [a + b for a, b in zip(totals, counts)]
        findings.extend(found)
    if nonempty == 0:
        problems.append(f"every stylesheet in {css_dir} is empty: nothing was checked")
    elif totals[0] == 0:
        problems.append(f"no file url() in any stylesheet in {css_dir}: nothing was resolved")
    return problems, Counts(*totals), findings


def report(repo_root: str, css_dir: str) -> int:
    problems, counts, findings = scan_dir(repo_root, css_dir)
    for problem in problems:
        print(f"css-url-resolution: INSTRUMENT FAILURE: {problem}")
    if problems:
        return 1
    print(f"css-url-resolution: {counts.files} file url() reference(s) resolved "
          f"(skipped: {counts.data} data:, {counts.fragment} fragment, {counts.remote} remote)")
    for f in findings:
        print(f"  MISSING {f.stylesheet}:{f.line}  url({f.url})  -> {f.looked_for}")
    if findings:
        print(
            "css-url-resolution: FAILED. A url() whose file does not exist compiles clean and\n"
            "  paints nothing. Add the file, or remove the rule if nothing uses it (see the\n"
            "  header of ci/test/css-url-resolution-guard.py for how urls are resolved)."
        )
        return 1
    return 0


# --- self-test ----------------------------------------------------------------

def self_test() -> int:
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")

    with tempfile.TemporaryDirectory() as root:
        for rel in ("src/public/resources/debug/stop_16.svg",
                    "libs/design/Font-Regular.ttf",
                    "src/public/resources/fonts/face.woff"):
            os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
            open(os.path.join(root, rel), "w").close()

        cases = [
            # (name, css, expected missing urls)
            ("a public resource the build copies",
             '.a { background: url("../../public/resources/debug/stop_16.svg") }', []),
            ("the same, reached through src/public by one more ../",
             ".a { background: url(../../../public/resources/debug/stop_16.svg) }", []),
            ("a design-system font outside the build dir",
             "@font-face { src: url('../../../../libs/design/Font-Regular.ttf') }", []),
            ("a query and fragment after the path",
             '@font-face { src: url("../../public/resources/fonts/face.woff?v=4.7.0#x") }', []),
            ("the dark jump icon that never existed",
             '#jump-before-image { background-image: url("../../public/resources/debug/jump-before_16_dark.svg") }',
             ["../../public/resources/debug/jump-before_16_dark.svg"]),
            ("a fallback beside the stylesheet, where nothing is copied",
             "@font-face { src: url(../../public/resources/fonts/face.woff), url(fontawesome-webfont.ttf) }",
             ["fontawesome-webfont.ttf"]),
            ("data:, fragment and remote urls are not files",
             '.a { mask: url("data:image/svg+xml,<svg/>"); filter: url(#f); background: url(https://x.test/y.png) }',
             []),
            ("a commented-out reference", "/* .a { background: url(missing.png) } */ .b { color: red }", []),
        ]
        for name, css, expected in cases:
            _, found = scan_text(root, "fixture.css", css)
            got = [f.url for f in found]
            check(name, got == expected, ", ".join(got) or "clean")

        with tempfile.TemporaryDirectory() as css_dir:
            problems, _, _ = scan_dir(root, css_dir)
            check("an empty stylesheet directory is an instrument failure", bool(problems))
            with open(os.path.join(css_dir, "theme.css"), "w", encoding="utf-8") as handle:
                handle.write("\n")
            problems, _, _ = scan_dir(root, css_dir)
            check("a directory of empty stylesheets is an instrument failure", bool(problems))
            with open(os.path.join(css_dir, "theme.css"), "w", encoding="utf-8") as handle:
                handle.write(".a { color: red }\n")
            problems, _, _ = scan_dir(root, css_dir)
            check("stylesheets with no file url() are an instrument failure", bool(problems))
            with open(os.path.join(css_dir, "theme.css"), "w", encoding="utf-8") as handle:
                handle.write(".a { background: url(nope.svg) }\n")
            status = report(root, css_dir)
            check("a missing file fails the report", status == 1)

    print("css-url-resolution self-test " + ("passed" if failures == 0 else f"FAILED ({failures})"))
    return 0 if failures == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", default=os.path.join(os.path.dirname(__file__), "..", ".."))
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--css-dir", help="directory of compiled stylesheets to check")
    group.add_argument("--self-test", action="store_true", help="run the planted fixtures")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return report(os.path.abspath(args.repo_root), args.css_dir)


if __name__ == "__main__":
    sys.exit(main())
