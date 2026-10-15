# godot

Builds of the [Godot Engine](https://godotengine.org) used by
[Wallpaper Reactor](https://wallpaperreactor.app) to run Godot wallpapers.

They are Godot export templates (release, no editor) with a small hardening for running
untrusted wallpapers: a wallpaper can read its own pack and write its own user folder, and
nothing else on the machine. This repository is **not a fork**. It holds three patch files, a
build profile and the scripts that build stock Godot with them. CI fetches the upstream tag,
checks the commit, applies the patches and builds every slice.

## Layout

| Path | What it is |
| --- | --- |
| `godot.env` | The upstream tag and the commit it must resolve to, and the SCons version |
| `patches/harden.patch` | The hardening, every slice (the hunks are listed below) |
| `patches/macos-accessory.patch` | One macOS change: no Dock icon for a wallpaper |
| `patches/movie-png-fast.patch` | A movie frame written as a PNG at zlib level 1 with the Sub filter, every slice (below) |
| `native-deny-list.json` | The methods the engine never binds. Data, not code: adding one is a JSON edit |
| `profile/trim.sh`, `profile/trim.gdbuild` | The trim: module switches, and classes compiled out |
| `slices.json` | The nine slices, their release asset names and their CI runners |
| `scripts/prepare.sh` | Checks a checkout is the pinned commit, applies the patches, writes the deny-list header |
| `scripts/build.sh` | Builds one slice. Every toolchain and archive is pinned by version or SHA-256 |
| `scripts/deny-header.py` | Generates the C++ header the deny-list hook includes |
| `check/` | The hardening check: runs a pack in the built engine and probes what it can reach |
| `tests/` | Tests for the scripts and the patches (`node --test tests/*.test.mjs`) |

## Building

```sh
scripts/build.sh <slice> [--jobs N] [--dry-run] [-- scons option...]
```

The slices are `linux`, `web`, `windows-x86_64`, `windows-arm64`, `macos`, `android-arm64`,
`android-arm32`, `android-x86_64` and `android-x86_32`. Output goes to
`$WR_GODOT_OUT/<asset>` with a `.sha256` beside it. `--dry-run` prints the scons options and
builds nothing. Everything after `--` goes to scons last, so it overrides. The desktop slices (Linux,
Windows, macOS) are built with `optimize=size lto=full`: a fifth to two fifths smaller, with no
measured cost in startup or frame rate. **No slice has a RenderingDevice driver** (Vulkan, D3D12,
Metal) or glslang: every wallpaper runs on the Compatibility renderer, on native OpenGL or on ANGLE
(D3D11 on Windows, Metal on macOS). A host passes `--rendering-method gl_compatibility
--rendering-driver opengl3` (or `opengl3_angle`), so a project that names `forward_plus` or `mobile`
still starts.

| Slice | Toolchain | Notes |
| --- | --- | --- |
| `linux` | Godot's buildroot SDK `godot-2023.08.x-4` (glibc 2.28) | Path overrides on, so `--main-pack` works |
| `web` | emscripten 4.0.20 | No threads |
| `windows-*` | llvm-mingw 20251118 | The official recipe less D3D12: ANGLE, AccessKit, WinRT |
| `macos` | Xcode 26.2 | Universal. ANGLE, no Metal or MoltenVK. Path overrides on. Unsigned. The SLP vectoriser is off so the output is reproducible |
| `android-*` | NDK 29.0.14206865 | `libgodot_android.so` for one ABI. Optimised for size. Swappy off |

To check a Linux or macOS build:

```sh
check/check-hardening.sh <engine> [refuse-list.json]   # prints HARDENING OK, or what failed
```

A stock engine fails this check, which is the control.

## The patches

Prefer a build option, a build-profile entry or an engine setting over a source change. These
hunks remain because nothing else can do their job. Every hunk in `harden.patch` is inside
`#ifndef TOOLS_ENABLED`, so the editor that exports packs is stock.

<!-- hunks -->
| File | Hunks | Purpose | Why it is not a build option |
| --- | --- | --- | --- |
| `core/object/class_db.cpp` | 4 | The deny-list hook. One helper asks the generated list, and each of the three bind paths (instance and static, vararg, custom) skips a denied `Class::method`. No script, `Callable`, `Object.call` or `ClassDB` lookup can then reach it | The build profile can disable whole classes only. `OS` and `DisplayServer` must stay, and only some of their methods go |
| `core/object/class_db.h` | 1 | `register_custom_instance_class` honours the build profile's `disabled_classes`. Stock registers these classes anyway, which left `HTTPClient` scriptable in a trimmed build | This is an upstream bug: `disabled_classes` is ignored on this path. An upstream fix would delete this hunk |
| `core/io/file_access.h` | 1 | The confinement state: the two allowed roots, the armed flag, and `WrTrusted`, which exempts the engine's own pack reads | No engine setting confines file access |
| `core/io/file_access.cpp` | 2 | The check itself, in `FileAccess::fix_path`, the funnel every platform's open, exists, copy, rename and remove goes through. A path outside `user://` (or the project directory, when no pack is mounted) resolves to a name no filesystem opens. `pipe://` is treated as a filesystem path once confined, because the pipe driver never calls `fix_path` | As above |
| `core/io/dir_access.cpp` | 1 | The same check in `DirAccess::fix_path`. A relative name is joined to the current directory first, as stock does, then confined. The GLES3 shader cache depends on that | As above |
| `core/io/file_access_pack.cpp` | 1 | The engine's own read of a pack it mounted is exempt: it reopens the pack's absolute path for every `res://` read | As above |
| `main/main.cpp` | 1 | Arms the confinement at the top of `Main::setup2`: the pack is mounted and the settings are read, and no script has run yet | As above |
| `core/io/marshalls.cpp` | 2 | `decode_variant` decodes no object once confined, whatever the caller asks. This covers `get_var`, `bytes_to_var_with_objects`, `decode_var` and `base64_to_variant`. The engine's own `project.binary` is read before that | `allow_objects` is a per-call argument. There is no global setting |
| `core/extension/gdextension_manager.cpp` | 1 | Reads the extension list past the pack (`SKIP_PACK`), so it is the host's list, never one a pack ships. Stock loads that list at start, before any script runs: native code a pack names | GDExtension cannot be compiled out, and a host may load its own extension |
| `platform/macos/os_macos.mm` | 1 | With `WR_GODOT_ACCESSORY` set, the engine starts as an accessory app: no Dock icon | The policy is set in code, which overrides `LSUIElement` |
| `platform/macos/godot_application.mm` | 1 | With `WR_GODOT_ACCESSORY` set, the engine never activates itself or takes focus | As above |
| `drivers/png/png_driver_common.h` | 1 | `movie-png-fast.patch`: declares `image_to_png_fast`, template builds only | The stock encoder takes no compression setting |
| `drivers/png/png_driver_common.cpp` | 1 | `image_to_png_fast`: the same pixels as `image_to_png`, written by libpng's full writer at zlib level 1 with the Sub filter (about seven times faster, a quarter larger); RGB8 and RGBA8 only, any other format takes the stock encoder | The simplified writer `image_to_png` uses has a fixed level 6 and every filter, or a fast flag at level 3 |
| `servers/movie_writer/movie_writer_pngwav.cpp` | 2 | `write_frame` calls `image_to_png_fast`, the one caller, so every other PNG save is stock | `--write-movie` has no setting for the PNG compression level |
<!-- /hunks -->

Already build options rather than patches: networking (the ENet, WebSocket, WebRTC, UPnP,
multiplayer and mbedTLS modules off), XR, Mono, and editor-only tooling (`profile/trim.sh`).
The core networking classes and `Expression` are listed in `profile/trim.gdbuild`.

## Updating Godot

1. Set the new tag and its commit in `godot.env`.
2. Run `scripts/prepare.sh` on a checkout of the new tag. Fix any hunk that no longer applies,
   and keep this README's table in step (`tests/patches.test.mjs` checks it).
3. Check the toolchain pins in `scripts/build.sh` against the new version's official build
   containers (emscripten, NDK, llvm-mingw, Xcode, and the library archives).
4. Push. CI builds every slice and runs the hardening check on Linux and macOS. To release a run: push the tag
   `godot-engine-<version>-wr<n>` on its commit, then run the `Release` workflow with the run id and the tag.
5. If a new engine method opens a new capability, add it to `native-deny-list.json`.

## Releases

Each release has every slice under its asset name in `slices.json`, a `.sha256` for each, one
`SHA256SUMS`, and a GitHub artifact attestation of each binary's provenance:

```sh
gh attestation verify <file> --repo wallpaper-reactor/godot
```

The macOS build is unsigned; whoever ships it signs it.

## Licence

The scripts and patches are under the MIT licence (`LICENSE`). Godot is under the MIT licence.
Each release carries Godot's `LICENSE.txt` and its third-party notices, `COPYRIGHT.txt`.
