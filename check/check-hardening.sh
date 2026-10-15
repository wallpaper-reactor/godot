#!/usr/bin/env bash
# Proves a built Godot engine is the hardened one: no method in native-deny-list.json is bound, no class the build
# profile (profile/trim.gdbuild) disables exists, nor any class a refuse list given as an extra file names,
# scripts reach res:// and user:// only, and FileAccess.get_var decodes no objects. ClassDB introspection and real
# calls, not a reading of the patch, so a hook that silently stopped applying after a Godot bump fails here.
#
# The check runs from a pack mounted with --main-pack (check/check.gd), as a wallpaper does; the engine under test
# packs it first. Needs an engine that runs on this machine and takes --main-pack and --path
# (an editor, or a template built with disable_path_overrides=no). A stock engine fails: that is the control.
#
# An engine built without path overrides (the Windows template) runs the check from a pack beside it instead:
# `--beside DIR` packs it as DIR/wr-check.pck with runner.gd as an autoload, using an engine that runs here, and runs
# nothing else. On the target: copy the engine beside it as wr-check(.exe), make a directory holding secret.txt, and
# run `wr-check --headless -- <that dir>/secret.txt <that dir>` in that directory.
#
# usage: check/check-hardening.sh <godot binary> [refuse-list.json]     exit 0 only on "HARDENING OK"
#        check/check-hardening.sh --beside DIR <godot binary> [refuse-list.json]
set -euo pipefail
limit=(timeout 120); command -v timeout >/dev/null || limit=()      # macOS has neither
command -v sha256sum >/dev/null || sha256sum() { shasum -a 256 "$@"; }
beside=""
if [[ "${1:-}" == --beside ]]; then beside="$2"; shift 2; fi
[[ ($# -eq 1 || $# -eq 2) && -x "$1" ]] || { echo "usage: $0 [--beside DIR] <godot binary> [refuse-list.json]" >&2; exit 2; }
engine="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

src="$tmp/src"; outside="$tmp/outside"
mkdir -p "$src" "$outside" "$tmp/xdg"
echo "outside res:// and user://" > "$outside/secret.txt"
cp "$here/check.gd" "$here/runner.gd" "$here/pack.gd" "$here/../native-deny-list.json" "$here/../profile/trim.gdbuild" "$src/"
if [[ $# -eq 2 ]]; then cp "$2" "$src/refuse-list.json"; else echo '{"networkingClasses": []}' > "$src/refuse-list.json"; fi
printf 'config_version=5\n\n[application]\n\nconfig/name="wr-hardening-check"\n' > "$src/project.godot"
# The pack --beside writes holds a project.godot with runner.gd as an autoload (packed from beside.godot, so it is not
# the one this engine packs with, where the autoload would run the check).
# A project starts only with a main scene: an empty one.
{ cat "$src/project.godot"; printf 'run/main_scene="res://main.tscn"\n\n[autoload]\n\nWrCheck="*res://runner.gd"\n'; } > "$src/beside.godot"
printf '[gd_scene format=3]\n\n[node name="Main" type="Node"]\n' > "$src/main.tscn"

# The engine's user:// and settings go under $tmp, never the real ~/.local/share or ~/.config (Linux; macOS ignores
# XDG, so there user:// is ~/Library/Application Support/Godot/app_userdata/wr-hardening-check).
run() { env XDG_DATA_HOME="$tmp/xdg/data" XDG_CONFIG_HOME="$tmp/xdg/config" XDG_CACHE_HOME="$tmp/xdg/cache" \
  ${limit[@]+"${limit[@]}"} "$engine" --headless "$@"; }

if [[ -n "$beside" ]]; then
  run --path "$src" --script res://pack.gd -- check.pck project.godot:beside.godot main.tscn check.gd runner.gd native-deny-list.json \
    refuse-list.json trim.gdbuild >"$tmp/pack.log" 2>&1 || { cat "$tmp/pack.log"; echo "could not pack the check" >&2; exit 1; }
  mkdir -p "$beside" && cp "$src/check.pck" "$beside/wr-check.pck"
  echo "packed $beside/wr-check.pck"
  exit 0
fi
run --path "$src" --script res://pack.gd >"$tmp/pack.log" 2>&1 || { cat "$tmp/pack.log"; echo "could not pack the check" >&2; exit 1; }
set +e
# In $outside, as a host once ran its engine in the slot: res:// must not reach the working directory (H10).
(cd "$outside" && run --main-pack "$src/check.pck" --script res://check.gd -- "$outside/secret.txt" "$outside") 2>&1 | tee "$tmp/check.log"
set -e
status=0
grep -qx "HARDENING OK" "$tmp/check.log" || status=1
for leak in "$outside/written.txt" "$outside/made"; do
  [[ ! -e "$leak" ]] || { echo "FAIL the engine created $leak"; status=1; }
done
echo "engine: $engine"
echo "sha256: $(sha256sum "$engine" | cut -d' ' -f1)"
[[ $status == 0 ]] && echo "godot-check-hardening: PASS" || echo "godot-check-hardening: FAIL"
exit $status
