# The trim: the engine that runs EVERY Godot wallpaper, including stock projects. It removes only what no wallpaper
# should use. Physics 2D/3D, navigation, particles, the runtime importers, audio, the text server and fonts, glTF and
# animation all stay. Sourced by scripts/build.sh, with profile/trim.gdbuild (the classes compiled out).
standard=(
  # XR: a wallpaper has no headset
  disable_xr=yes module_openxr_enabled=no module_mobile_vr_enabled=no module_webxr_enabled=no
  # C#/Mono: not built (no .NET runtime in the app); stated so the scanner can refuse C# projects
  module_mono_enabled=no
  # editor/debug-only tooling (a release template has no editor; these are the leftovers)
  module_objectdb_profiler_enabled=no module_jsonrpc_enabled=no
  # SECURITY, not size: a wallpaper must not open sockets
  module_enet_enabled=no module_websocket_enabled=no module_webrtc_enabled=no module_upnp_enabled=no
  module_multiplayer_enabled=no module_mbedtls_enabled=no
)
# plus engine/standard-trim.gdbuild: the core networking classes (SECURITY: HTTP, TCP, UDP, DTLS/TLS)
