#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
OUT_DIR="${2:-$ROOT_DIR/stylus}"

mkdir -p "$OUT_DIR"

python3 - "$ROOT_DIR" "$OUT_DIR" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

ROOT_DIR = Path(sys.argv[1]).resolve()
OUT_DIR = Path(sys.argv[2]).resolve()

EXPECTED_FOLDERS = ["brand", "alias", "mapped"]

def find_single_json(folder: Path) -> Path:
    if not folder.exists() or not folder.is_dir():
        raise SystemExit(f"[ERROR] Missing folder: {folder}")
    files = sorted([p for p in folder.iterdir() if p.is_file() and p.suffix.lower() == ".json"])
    if not files:
        raise SystemExit(f"[ERROR] No .json file found in: {folder}")
    if len(files) > 1:
        raise SystemExit(
            f"[ERROR] Expected exactly 1 .json file in {folder}, found {len(files)}: "
            + ", ".join(p.name for p in files)
        )
    return files[0]

def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit(f"[ERROR] Invalid JSON in {path}: {e}")

def sanitize_part(part: str) -> str:
    part = str(part).strip().lower()
    part = part.replace("&", " and ")
    part = re.sub(r"[^a-z0-9]+", "-", part)
    part = re.sub(r"-{2,}", "-", part).strip("-")
    return part or "token"

def path_to_var(path_parts):
    return "-".join(sanitize_part(p) for p in path_parts)

REF_RE = re.compile(r"^\{([^{}]+)\}$")

def ref_to_var(ref_text: str) -> str:
    inner = ref_text.strip()[1:-1].strip()
    parts = [p.strip() for p in inner.split(".")]
    return path_to_var(parts)

def is_hex_color(s: str) -> bool:
    return bool(re.fullmatch(r"#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})", s))

def is_css_dimension(s: str) -> bool:
    return bool(re.fullmatch(r"-?\d+(?:\.\d+)?(?:px|rem|em|vh|vw|%)", s))

def quote_string(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)

def stylus_scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        value = value.strip()
        if REF_RE.fullmatch(value):
            return ref_to_var(value)
        if is_hex_color(value):
            return value
        if is_css_dimension(value):
            return value
        return quote_string(value)
    return None

def stylus_value(value, indent=0):
    scalar = stylus_scalar(value)
    if scalar is not None:
        return scalar

    if isinstance(value, dict):
        pad = "  " * indent
        inner = "  " * (indent + 1)
        lines = ["{"]
        for k, v in value.items():
            key = sanitize_part(k)
            rendered = stylus_value(v, indent + 1)
            lines.append(f"{inner}{key}: {rendered}")
        lines.append(f"{pad}" + "}")
        return "\n".join(lines)

    if isinstance(value, list):
        rendered = ", ".join(stylus_value(v, indent) for v in value)
        return f"[{rendered}]"

    return quote_string(str(value))

def flatten_tokens(node, path=None, out=None):
    if path is None:
        path = []
    if out is None:
        out = {}

    if isinstance(node, dict):
        if "$value" in node:
            out[tuple(path)] = {
                "type": node.get("$type"),
                "value": node.get("$value"),
            }
            return out

        for key, value in node.items():
            if key.startswith("$"):
                continue
            flatten_tokens(value, path + [key], out)

    return out

def collect_all_vars(*flat_maps):
    vars_set = set()
    for flat in flat_maps:
        for token_path in flat.keys():
            vars_set.add(path_to_var(token_path))
    return vars_set

def render_file(title, flat_map, known_vars):
    lines = []
    lines.append(f"// Auto-generated from {title}.json")
    lines.append(f"// Source layer: {title}")
    lines.append("")

    unresolved = []

    for token_path in sorted(flat_map.keys(), key=lambda p: [sanitize_part(x) for x in p]):
        token = flat_map[token_path]
        var_name = path_to_var(token_path)
        rendered = stylus_value(token["value"])

        refs = []
        def gather_refs(v):
            if isinstance(v, str) and REF_RE.fullmatch(v):
                refs.append(ref_to_var(v))
            elif isinstance(v, dict):
                for vv in v.values():
                    gather_refs(vv)
            elif isinstance(v, list):
                for vv in v:
                    gather_refs(vv)

        gather_refs(token["value"])
        for ref in refs:
            if ref not in known_vars:
                unresolved.append((var_name, ref))

        lines.append(f"{var_name} = {rendered}")
        lines.append("")

    if unresolved:
        lines.append("// Unresolved references detected:")
        for src, ref in unresolved:
            lines.append(f"// {src} -> {ref}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"

brand_json = find_single_json(ROOT_DIR / "brand")
alias_json = find_single_json(ROOT_DIR / "alias")
mapped_json = find_single_json(ROOT_DIR / "mapped")

brand_data = load_json(brand_json)
alias_data = load_json(alias_json)
mapped_data = load_json(mapped_json)

brand_flat = flatten_tokens(brand_data)
alias_flat = flatten_tokens(alias_data)
mapped_flat = flatten_tokens(mapped_data)

known_vars = collect_all_vars(brand_flat, alias_flat, mapped_flat)

brand_out = render_file("brand", brand_flat, known_vars)
alias_out = render_file("alias", alias_flat, known_vars)
mapped_out = render_file("mapped", mapped_flat, known_vars)

(OUT_DIR / "brand.styl").write_text(brand_out, encoding="utf-8")
(OUT_DIR / "alias.styl").write_text(alias_out, encoding="utf-8")
(OUT_DIR / "mapped.styl").write_text(mapped_out, encoding="utf-8")

index_out = "\n".join([
    "// Auto-generated import index",
    '@import "brand.styl"',
    '@import "alias.styl"',
    '@import "mapped.styl"',
    "",
])
(OUT_DIR / "index.styl").write_text(index_out, encoding="utf-8")

print(f"[OK] brand json : {brand_json}")
print(f"[OK] alias json : {alias_json}")
print(f"[OK] mapped json: {mapped_json}")
print(f"[OK] wrote      : {OUT_DIR / 'brand.styl'}")
print(f"[OK] wrote      : {OUT_DIR / 'alias.styl'}")
print(f"[OK] wrote      : {OUT_DIR / 'mapped.styl'}")
print(f"[OK] wrote      : {OUT_DIR / 'index.styl'}")
PY
