# Runs check.gd from an autoload, for an engine built without path overrides (no --main-pack, no --script): its pack
# sits beside it as <engine name>.pck (check-hardening.sh --beside). User args as check.gd's.
extends Node


func _ready() -> void:
	get_tree().quit(load("res://check.gd").run(OS.get_cmdline_user_args()))
