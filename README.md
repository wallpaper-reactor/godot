# godot

Builds of the [Godot Engine](https://godotengine.org) used by
[Wallpaper Reactor](https://wallpaperreactor.app) to render Godot wallpapers.

They are Godot 4.7.2-stable (`ed1daf0b`) export templates (release, no editor) with Wallpaper
Reactor's hardening for running untrusted wallpapers: a wallpaper can read its own pack and
write its own user folder, and nothing else on the machine. Wallpaper Reactor's `wr` command
line tool downloads the engine for its platform on first use and checks its SHA-256 before
running it.

## Releases

| Release | Asset | Platform |
| --- | --- | --- |
| [`godot-engine-4.7.2-wr3`](https://github.com/wallpaper-reactor/godot/releases/tag/godot-engine-4.7.2-wr3) | `godot_linux_release_wr.x86_64` | Linux x86_64, glibc 2.38 or later |

Each binary has a `.sha256` beside it. Windows and macOS builds ship inside the Wallpaper
Reactor app itself and are not published here.

## Licence

Godot is under the MIT licence. Each release carries Godot's `LICENSE.txt` and its third-party
notices, `COPYRIGHT.txt`, beside the binaries.
