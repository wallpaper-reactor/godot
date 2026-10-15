#!/usr/bin/env bash
# Makes a Godot checkout the hardened engine's source: checks it is the commit godot.env pins, applies
# patches/harden.patch and any extra patch named (the macOS slice adds patches/macos-accessory.patch), and writes
# core/object/wr_native_deny_list.gen.h from native-deny-list.json. A checkout already carrying some or all of
# them gets the rest; any other change to a tracked file is refused.
#
# usage: scripts/prepare.sh <godot checkout> [extra patch...]
set -euo pipefail
# A caller's GIT_DIR (a hook's, say) must not point these git commands at another repository.
while read -r v; do unset "$v"; done < <(env | grep -o '^GIT_[A-Z_]*' || true)

engine="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "[godot-engine] error: $*" >&2; exit 1; }
[[ $# -ge 1 ]] || die "usage: $0 <godot checkout> [extra patch...]"
# shellcheck source=../godot.env
source "$engine/godot.env"
src="$(cd "$1" && pwd)"; shift
patches=("$engine/patches/harden.patch")
for p in "$@"; do patches+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"); done
g() { git -C "$src" "$@"; }

got="$(g rev-parse HEAD)"
[[ "$got" == "$GODOT_COMMIT" ]] || die "$src is at $got, pinned $GODOT_COMMIT ($GODOT_TAG)"

# The tree the checkout should have (the commit plus the patches) against the tree it has (tracked files only).
idx="$(mktemp -d)"; trap 'rm -rf "$idx"' EXIT
want="$(GIT_INDEX_FILE="$idx/want" g read-tree HEAD && GIT_INDEX_FILE="$idx/want" g apply --cached "${patches[@]}" \
  && GIT_INDEX_FILE="$idx/want" g write-tree)" || die "the patches do not apply to $GODOT_COMMIT"
have() { GIT_INDEX_FILE="$idx/have" g read-tree HEAD && GIT_INDEX_FILE="$idx/have" g add -u && GIT_INDEX_FILE="$idx/have" g write-tree; }
# Each patch the checkout does not carry yet is applied.
for p in "${patches[@]}"; do
  g apply --reverse --check "$p" 2>/dev/null || g apply "$p" 2>/dev/null || die "${p##*/} does not apply to $src"
done
[[ "$(have)" == "$want" ]] || die "$src differs from $GODOT_COMMIT plus $(printf '%s ' "${patches[@]##*/}")alone"

python3 "$engine/scripts/deny-header.py" "$src/core/object/wr_native_deny_list.gen.h"
digest="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$engine/native-deny-list.json")"
echo "[godot-engine] $src: $GODOT_TAG ($GODOT_COMMIT) + $(printf '%s ' "${patches[@]##*/}")+ the deny list (${digest:0:12})"
