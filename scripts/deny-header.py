#!/usr/bin/env python3
"""Generates the hardened engine's deny-list header from native-deny-list.json. patches/harden.patch's bind-path hook
includes it as core/object/wr_native_deny_list.gen.h; scripts/prepare.sh writes it into a Godot checkout.

usage: deny-header.py OUT [--list PATH]
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--list", default=str(ENGINE / "native-deny-list.json"))
    args = ap.parse_args()
    raw = Path(args.list).read_bytes()
    methods = json.loads(raw)["methods"]
    rows = []
    for cls, names in methods.items():
        for name in names:
            if not (IDENT.match(cls) and IDENT.match(name)):
                raise SystemExit(f"not an identifier: {cls}::{name}")
            rows.append(f'\t{{"{cls}", "{name}"}},')
    digest = hashlib.sha256(raw).hexdigest()
    Path(args.out).write_text(
        "// Generated from native-deny-list.json by scripts/deny-header.py. Do not edit.\n"
        "#pragma once\n\n"
        "// The list's digest, kept in the binary so a built engine can be matched to the list it was built with.\n"
        f'static const char *const WR_NATIVE_DENY_LIST_ID = "WR_NATIVE_DENY_LIST_SHA256={digest}";\n\n'
        "static const char *const WR_NATIVE_DENY_LIST[][2] = {\n" + "\n".join(rows) + "\n};\n"
    )


if __name__ == "__main__":
    main()
