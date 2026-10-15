#!/usr/bin/env bash
# Builds one slice of the hardened Godot engine (slices.json names them and their assets): the source godot.env pins,
# made ready by scripts/prepare.sh (patches/harden.patch and the deny-list header; macOS adds
# patches/macos-accessory.patch), the trim (profile/trim.sh module switches, profile/trim.gdbuild disabled classes),
# then scons with the slice's options.
#
#   linux    the Linux release template with path overrides on (--main-pack and --path work): what the hardening check
#            runs. Godot's own Linux SDK (buildroot, glibc 2.28), as the official build.
#   web      the no-threads web release template, with the emscripten Godot's 4.7 build container uses
#   windows-<x86_64|arm64>
#            cross-built with llvm-mingw: the official 4.7 recipe (production, ANGLE, AccessKit, WinRT) less D3D12, each
#            library the llvm build of the version that recipe pins. Path overrides stay compiled out, as in
#            the official template: a host runs the engine beside its pack.
#   macos    universal (x86_64 and arm64 joined with lipo), path overrides on, the official 4.7 recipe (ANGLE, AccessKit)
#            less Metal and MoltenVK on Xcode XCODE_VERSION, the SLP vectoriser off (below). Unsigned: whoever ships it signs it.
#   android-<arm64|arm32|x86_64|x86_32>
#            libgodot_android.so for one ABI, with the NDK this Godot pins; optimize=size; swappy off (Vulkan frame pacing).
#
# No slice has a RenderingDevice driver (Vulkan, D3D12, Metal) or glslang: every wallpaper runs on the Compatibility
# renderer, on native OpenGL or on ANGLE (D3D11 on Windows, Metal on macOS), and every host passes
# --rendering-method gl_compatibility so a project naming forward_plus or mobile still starts
# (docs/evidence/godot-hardening/trim/README.md, wr6).
#
# Every input is pinned: the source commit (godot.env), SCons, each downloaded archive by SHA-256, each toolchain by
# version. The SLP vectoriser is off on macOS because it is not deterministic in Xcode's clang (the same command gave
# one of two objects about half the time); `-mllvm -vectorize-slp=false` sits in ccflags because Godot puts ccflags
# before its -O3, which would turn -fno-slp-vectorize back on.
#
# Source: $WR_GODOT_SRC (default $cache/godot, cloned at the tag when missing). Toolchains and archives: $cache
# ($WR_GODOT_CACHE, default ~/.cache/wr-godot-engine). Output: $WR_GODOT_OUT (default $cache/out)/<asset>, and
# <asset>.sha256 beside it. Extra scons options after `--` come last, so they override (the trim measurements use it).
# --dry-run prints the output and the options and touches nothing.
#
# usage: scripts/build.sh <slice> [--jobs N] [--dry-run] [-- scons option...]
set -euo pipefail
while read -r v; do unset "$v"; done < <(env | grep -o '^GIT_[A-Z_]*' || true)

engine="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../godot.env
source "$engine/godot.env"
# shellcheck source=../profile/trim.sh
source "$engine/profile/trim.sh"   # standard=(...)

EMSCRIPTEN_VERSION=4.0.20                             # Godot's 4.7 build container (build-containers, Dockerfile.web)
EMSDK_COMMIT=e4fe26ef59168ff44f4c23c466e497bf60b3411e # emsdk's tag 4.0.20
ANDROID_NDK_VERSION=29.0.14206865                     # platform/android/detect.py get_ndk_version()
XCODE_VERSION=26.2
LLVM_MINGW=llvm-mingw-20251118-ucrt-ubuntu-22.04-x86_64.tar.xz   # the 4.7 Windows build container's

die() { echo "[godot-engine] error: $*" >&2; exit 1; }
usage() { echo "usage: $0 <$(python3 -c 'import json,sys; print("|".join(json.load(open(sys.argv[1]))["slices"]))' "$engine/slices.json")> [--jobs N] [--dry-run] [-- scons option...]" >&2; exit 2; }

slice="${1:-}"; shift || true
jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
dry=0 extra=()
while (($#)); do
  case "$1" in
    --jobs) jobs="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --) shift; extra=("$@"); break ;;
    *) usage ;;
  esac
done
asset="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["slices"].get(sys.argv[2], {}).get("asset", ""))' "$engine/slices.json" "$slice")"
[[ -n "$asset" ]] || usage

cache="${WR_GODOT_CACHE:-$HOME/.cache/wr-godot-engine}"
SRC="${WR_GODOT_SRC:-$cache/godot}"
OUT="${WR_GODOT_OUT:-$cache/out}"
deps="$cache/deps"
common=(target=template_release production=yes "${standard[@]}" "build_profile=$engine/profile/trim.gdbuild"
        vulkan=no module_glslang_enabled=no warnings=no progress=no)
# The desktop slices: optimised for size with full LTO, a third smaller with no measured cost in startup or fps
# (Android is already optimize=size).
desktop=(optimize=size lto=full)
patches=()
case "$slice" in
  linux)
    opts=(platform=linuxbsd arch=x86_64 disable_path_overrides=no "${desktop[@]}" "${common[@]}")
    built=(bin/godot.linuxbsd.template_release.x86_64) ;;
  web)
    opts=(platform=web threads=no "${common[@]}")
    built=(bin/godot.web.template_release.wasm32.nothreads.zip) ;;
  windows-x86_64|windows-arm64)
    arch="${slice#windows-}"
    opts=(platform=windows "arch=$arch" "${desktop[@]}" use_mingw=yes use_llvm=yes "mingw_prefix=$deps/llvm-mingw" d3d12=no
          "angle_libs=$deps/angle" "accesskit_sdk_path=$deps/accesskit/accesskit-c"
          "winrt_path=$deps/winrt" "linkflags=-Wl,--no-insert-timestamp" "${common[@]}")   # no link time: reproducible
    built=("bin/godot.windows.template_release.$arch.llvm.exe") ;;
  macos)
    opts=(platform=macos "${desktop[@]}" metal=no disable_path_overrides=no "ccflags=-mllvm -vectorize-slp=false"
          "angle_libs=$deps/angle" "accesskit_sdk_path=$deps/accesskit/accesskit-c"
          "${common[@]}")
    patches=("$engine/patches/macos-accessory.patch")
    built=(bin/godot.macos.template_release.x86_64 bin/godot.macos.template_release.arm64) ;;
  android-*)
    arch="${slice#android-}"
    declare -A abi=([arm64]=arm64-v8a [arm32]=armeabi-v7a [x86_64]=x86_64 [x86_32]=x86)
    opts=(platform=android "arch=$arch" optimize=size swappy=no "${common[@]}")
    built=("platform/android/java/lib/libs/release/${abi[$arch]}/libgodot_android.so") ;;
esac
opts+=(${extra[@]+"${extra[@]}"})

if ((dry)); then
  echo "slice: $slice"
  echo "output: $OUT/$asset"
  printf 'option: %s\n' "${opts[@]}"
  exit 0
fi

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
# fetch <name> <sha256> <url>: into $deps/dl, refused unless it hashes to the pin.
fetch() {
  local name="$1" want="$2" url="$3"
  mkdir -p "$deps/dl"
  [[ -f "$deps/dl/$name" && "$(sha "$deps/dl/$name")" == "$want" ]] && return
  echo "[godot-engine] fetching $url"
  curl -fL --retry 3 -o "$deps/dl/$name.part" "$url"
  [[ "$(sha "$deps/dl/$name.part")" == "$want" ]] || { rm -f "$deps/dl/$name.part"; die "$url is not the pinned $want"; }
  mv "$deps/dl/$name.part" "$deps/dl/$name"
}
# unpack <archive> <dir> [tar options]: a fresh extraction, so a changed pin never mixes with an old tree.
unpack() {
  local archive="$1" dir="$2"; shift 2
  [[ -f "$dir/.from" && "$(cat "$dir/.from")" == "$archive" ]] && return
  rm -rf "$dir"; mkdir -p "$dir"
  case "$archive" in *.zip) unzip -q -o "$deps/dl/$archive" -d "$dir" ;; *) tar -xf "$deps/dl/$archive" -C "$dir" "$@" ;; esac
  echo "$archive" > "$dir/.from"
}

# The source and SCons, before a toolchain puts its own python3 on PATH (the Linux SDK's has no ssl module).
if [[ ! -d "$SRC/.git" ]]; then
  git clone -q --depth 1 --branch "$GODOT_TAG" https://github.com/godotengine/godot.git "$SRC"
fi
"$engine/scripts/prepare.sh" "$SRC" ${patches[@]+"${patches[@]}"}
if [[ ! -x "$cache/venv/bin/scons" ]] || ! "$cache/venv/bin/scons" --version | grep -q "v$SCONS_VERSION"; then
  python3 -m venv "$cache/venv"
  "$cache/venv/bin/pip" install --quiet "SCons==$SCONS_VERSION"
fi

# The toolchain and libraries of the slice.
angle=https://github.com/godotengine/godot-angle-static/releases/download/chromium%2F7578/godot-angle-static
accesskit() {
  fetch accesskit-c-0.22.3.zip 41b30b1382d03b225b6f7e8721269a32557a68065804f3797bdffc34a3273498 \
    https://github.com/godotengine/godot-accesskit-c-static/releases/download/0.22.3/accesskit-c-0.22.3.zip
  unpack accesskit-c-0.22.3.zip "$deps/accesskit"
  [[ -d "$deps/accesskit/accesskit-c" ]] || mv "$deps/accesskit"/accesskit-c-* "$deps/accesskit/accesskit-c"
}
case "$slice" in
  linux)
    sdk=x86_64-godot-linux-gnu_sdk-buildroot
    fetch "$sdk.tar.bz2" b89f173b1f2f2f35f3090bc4efad732f1c0c1c1206e5480cfcb141977010bc94 \
      "https://github.com/godotengine/buildroot/releases/download/godot-2023.08.x-4/$sdk.tar.bz2"
    if [[ ! -f "$deps/$sdk/.from" || "$(cat "$deps/$sdk/.from")" != "$sdk.tar.bz2" ]]; then
      unpack "$sdk.tar.bz2" "$deps/$sdk" --strip-components=1
      (cd "$deps/$sdk" && ./relocate-sdk.sh >/dev/null && ln -sf x86_64-godot-linux-gnu-objcopy bin/objcopy \
        && ln -sf x86_64-godot-linux-gnu-strip bin/strip)
    fi
    command -v wayland-scanner >/dev/null || die "wayland-scanner is needed (Debian/Ubuntu: libwayland-bin)"
    export PATH="$deps/$sdk/bin:$PATH" ;;
  web)
    export EMSDK="$deps/emsdk"
    if [[ ! -d "$EMSDK/.git" ]]; then
      git clone -q --branch "$EMSCRIPTEN_VERSION" https://github.com/emscripten-core/emsdk.git "$EMSDK"
    fi
    [[ "$(git -C "$EMSDK" rev-parse HEAD)" == "$EMSDK_COMMIT" ]] || die "$EMSDK is not emsdk $EMSCRIPTEN_VERSION ($EMSDK_COMMIT)"
    "$EMSDK/emsdk" install "$EMSCRIPTEN_VERSION" >/dev/null
    "$EMSDK/emsdk" activate "$EMSCRIPTEN_VERSION" >/dev/null
    # shellcheck disable=SC1091
    source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
    emcc --version | head -1 | grep -qF " $EMSCRIPTEN_VERSION " || die "emcc is not $EMSCRIPTEN_VERSION" ;;
  windows-*)
    fetch "$LLVM_MINGW" 53a0c22caa46b501e1c089e1c31b24a7c0e0d5a86f8ad12b131aafd4cee01ef4 \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/20251118/$LLVM_MINGW"
    fetch winrt-headers-72.zip 9310868d0a82d11b7ae1943c4f35c202c6c9a692ee2deec4bde241fbe2639961 \
      https://github.com/godotengine/winrt-mingw/releases/download/72/winrt-headers.zip
    case "$arch" in
      x86_64)
        fetch angle-x86_64-llvm.zip 5d18ac9682e78aa712ced326ea05ff21822a2dda1e714547b5aca1f07e952b29 "$angle-x86_64-llvm-release.zip" ;;
      arm64)
        fetch angle-arm64-llvm.zip 4b6147fc84e98d5463a9172ca1141c6a03dbfcdd6d4800ab1bcc69e724d2f9fa "$angle-arm64-llvm-release.zip" ;;
    esac
    accesskit
    unpack "$LLVM_MINGW" "$deps/llvm-mingw" --strip-components=1
    unpack winrt-headers-72.zip "$deps/winrt"
    # Godot looks for <angle_libs>-<arch>-llvm.
    unpack "angle-$arch-llvm.zip" "$deps/angle-$arch-llvm"
    export MINGW_PREFIX="$deps/llvm-mingw" ;;   # the platform is offered only when this names a mingw (detect.py can_build)
  macos)
    [[ "$(uname -s)" == Darwin ]] || die "the macos slice builds on macOS with Xcode $XCODE_VERSION"
    xcodebuild -version | head -1 | grep -qx "Xcode $XCODE_VERSION" || die "needs Xcode $XCODE_VERSION (xcode-select -s), not $(xcodebuild -version | head -1)"
    fetch angle-arm64-macos.zip 9eadd2055f66507e9d74655e7683e068e7e4a9dade5a84bc03d3f5affdfb7b9d "$angle-arm64-macos-release.zip"
    fetch angle-x86_64-macos.zip 4e11d10e01b4a5e06f24afbafc3302d7ee3135bd6b076d6f818b1c87a8b18b94 "$angle-x86_64-macos-release.zip"
    accesskit
    if [[ ! -f "$deps/angle/.from" ]]; then
      mkdir -p "$deps/angle"
      unzip -q -o "$deps/dl/angle-arm64-macos.zip" -d "$deps/angle"
      unzip -q -o "$deps/dl/angle-x86_64-macos.zip" -d "$deps/angle"
      echo both > "$deps/angle/.from"
    fi ;;
  android-*)
    export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
    if [[ ! -d "$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION" ]]; then
      sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
      [[ -x "$sdkmanager" ]] || die "no NDK $ANDROID_NDK_VERSION in $ANDROID_HOME, and no sdkmanager to install it"
      "$sdkmanager" --install "ndk;$ANDROID_NDK_VERSION" >/dev/null
    fi ;;
esac

start=$(date +%s)
mkdir -p "$OUT"
if [[ "$slice" == macos ]]; then
  for arch in x86_64 arm64; do
    echo "[godot-engine] scons arch=$arch ${opts[*]}"
    (cd "$SRC" && "$cache/venv/bin/scons" -j"$jobs" "arch=$arch" "${opts[@]}")
  done
  lipo -create "$SRC/${built[0]}" "$SRC/${built[1]}" -output "$OUT/$asset"
  chmod 755 "$OUT/$asset"
  # Path overrides took (the stock template refuses --main-pack with this message), and so did the macOS patch.
  if strings -a "$OUT/$asset" | grep -q '`--main-pack` was specified on the command line, but this Godot binary was compiled without'; then
    die "$asset still refuses --main-pack; disable_path_overrides=no did not take"
  fi
  grep -qa WR_GODOT_ACCESSORY "$OUT/$asset" || die "$asset does not carry macos-accessory.patch"
else
  echo "[godot-engine] scons ${opts[*]}"
  (cd "$SRC" && "$cache/venv/bin/scons" -j"$jobs" "${opts[@]}")
  cp "$SRC/${built[0]}" "$OUT/$asset"
fi

# The deny list a binary was built with is in it (WR_NATIVE_DENY_LIST_SHA256=...); a zip holds it in its wasm.
if [[ "$asset" == *.zip ]]; then marker="$(unzip -p "$OUT/$asset" '*.wasm' | grep -aoE 'WR_NATIVE_DENY_LIST_SHA256=[0-9a-f]{64}' | head -1 || true)"
else marker="$(grep -aoE 'WR_NATIVE_DENY_LIST_SHA256=[0-9a-f]{64}' "$OUT/$asset" | head -1 || true)"; fi
want="WR_NATIVE_DENY_LIST_SHA256=$(sha "$engine/native-deny-list.json")"
[[ "$marker" == "$want" ]] || die "$asset does not carry $want (found '${marker:-nothing}')"
# ANGLE is Compatibility's fallback where native OpenGL cannot start (D3D11 beneath it on Windows, Metal on macOS), and a
# host asks for it (opengl3_angle): the RD drivers going must not take it with them. The message is ANGLE_ENABLED code's.
case "$slice" in windows-*|macos)
  grep -qa 'Could not initialize ANGLE OpenGL.' "$OUT/$asset" || die "$asset has no ANGLE (angle_libs did not take)" ;;
esac
digest="$(sha "$OUT/$asset")"
echo "$digest  $asset" > "$OUT/$asset.sha256"
echo "[godot-engine] $slice built in $(( $(date +%s) - start )) s: $OUT/$asset ($(wc -c < "$OUT/$asset" | tr -d ' ') bytes, sha256 $digest)"
