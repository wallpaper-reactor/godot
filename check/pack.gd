# Packs the hardening check (check-hardening.sh) into res://check.pck with the engine under test, or, given user args
# `<out.pck> <file>...`, those project files into res://<out.pck>.
extends SceneTree

const FILES := ["project.godot", "check.gd", "native-deny-list.json", "refuse-list.json", "trim.gdbuild"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "check.pck" if args.is_empty() else args[0]
	var files: Array = FILES if args.is_empty() else Array(args.slice(1))
	var packer := PCKPacker.new()
	var err := packer.pck_start("res://" + out)
	for name in files:
		if err == OK:
			err = packer.add_file("res://" + name, "res://" + name)
	if err == OK:
		err = packer.flush()
	print("packed" if err == OK else "pack failed: %s" % error_string(err))
	quit(0 if err == OK else 1)
