# The hardened engine's proof. check-hardening.sh packs this with the deny list and the build profile and mounts it
# with --main-pack, so it sees exactly what a wallpaper sees.
# Each line is "PASS <what>" or "FAIL <what>"; the last is "HARDENING OK" or "HARDENING FAILED <n>".
# User args: <a file outside res:// and user://> <the directory holding it>.
extends SceneTree

var failures := 0


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func _json(path: String):
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var outside_file: String = args[0]
	var outside_dir: String = args[1]
	_methods()
	_classes()
	_paths(outside_file, outside_dir)
	_get_var()
	print("HARDENING OK" if failures == 0 else "HARDENING FAILED %d" % failures)
	quit(0 if failures == 0 else 1)


# Every method in godot/native-deny-list.json is absent from ClassDB, and from the singleton a script would call.
func _methods() -> void:
	var deny = _json("res://native-deny-list.json")
	check(deny is Dictionary and deny.has("methods"), "control: res://native-deny-list.json reads")
	check(ClassDB.class_has_method("OS", "get_cmdline_user_args", true), "control: OS.get_cmdline_user_args is bound")
	for cls in deny.methods:
		var bound := {}
		for m in ClassDB.class_get_method_list(cls, true):
			bound[m.name] = true
		var singleton = Engine.get_singleton(cls) if Engine.has_singleton(cls) else null
		for name in deny.methods[cls]:
			var reachable: bool = bound.has(name) or ClassDB.class_has_method(cls, name, true) \
				or (singleton != null and singleton.has_method(name))
			check(not reachable, "%s.%s is not bound" % [cls, name])


# Every networking class the refuse list names, and every class the build profile disables, does not exist.
func _classes() -> void:
	var disabled: Array = []
	disabled.append_array(_json("res://refuse-list.json").networkingClasses)
	disabled.append_array(_json("res://trim.gdbuild").disabled_classes)
	check(disabled.has("Expression"), "control: the build profile disables Expression")
	for name in disabled:
		check(not ClassDB.class_exists(name), "class %s does not exist" % name)


# Scripts reach res:// (the pack) and user:// only: absolute paths, '..' and the OS-path helpers find nothing.
func _paths(outside_file: String, outside_dir: String) -> void:
	check(FileAccess.open("res://check.gd", FileAccess.READ) != null, "control: res://check.gd opens")
	var mine := FileAccess.open("user://wr-check.txt", FileAccess.WRITE)
	check(mine != null, "control: user:// is writable")
	if mine != null:
		mine.store_string("mine")
		mine.close()
	check(FileAccess.get_file_as_string("user://wr-check.txt") == "mine", "control: user:// reads back")
	var up := "../".repeat(24) + outside_file.trim_prefix("/")
	check(FileAccess.open(outside_file, FileAccess.READ) == null, "FileAccess.open(<absolute>) is refused")
	check(not FileAccess.file_exists(outside_file), "FileAccess.file_exists(<absolute>) is false")
	check(FileAccess.get_file_as_bytes(outside_file).is_empty(), "FileAccess.get_file_as_bytes(<absolute>) is empty")
	check(FileAccess.open("res://" + up, FileAccess.READ) == null, "res://../ does not escape")
	# The engine runs in outside_dir (godot-check-hardening.sh): a res:// name the pack lacks is not the working directory.
	var name := outside_file.get_file()
	check(FileAccess.open("res://" + name, FileAccess.READ) == null, "res://<a file in the working directory> is refused")
	check(not FileAccess.file_exists("res://" + name), "FileAccess.file_exists(res://<working directory file>) is false")
	check(FileAccess.open("res://written.txt", FileAccess.WRITE) == null, "a res:// write into the working directory is refused")
	check(FileAccess.open("user://" + up, FileAccess.READ) == null, "user://../ does not escape")
	check(FileAccess.open(outside_dir.path_join("written.txt"), FileAccess.WRITE) == null, "an absolute write is refused")
	check(DirAccess.open(outside_dir) == null, "DirAccess.open(<absolute>) is refused")
	check(not DirAccess.dir_exists_absolute(outside_dir), "DirAccess.dir_exists_absolute(<absolute>) is false")
	check(DirAccess.make_dir_absolute(outside_dir.path_join("made")) != OK, "DirAccess.make_dir_absolute(<absolute>) fails")
	check(DirAccess.copy_absolute(outside_file, "user://stolen-a.txt") != OK, "DirAccess.copy_absolute(<absolute>) fails")
	var user := DirAccess.open("user://")
	check(user != null, "control: DirAccess.open(user://) opens")
	if user != null:
		check(not user.file_exists(outside_file), "a user:// DirAccess does not see <absolute>")
		check(user.copy(outside_file, "user://stolen-b.txt") != OK, "a user:// DirAccess cannot copy <absolute> in")
		check(user.change_dir(outside_dir) != OK, "a user:// DirAccess cannot change_dir to <absolute>")
		# Relative names resolve against the DirAccess's current directory, as stock does (the GLES3 shader cache
		# walks user://shader_cache so), and stay confined.
		check(user.make_dir("wr-rel") in [OK, ERR_ALREADY_EXISTS] and user.change_dir("wr-rel") == OK \
			and user.make_dir("inner") in [OK, ERR_ALREADY_EXISTS] and DirAccess.dir_exists_absolute("user://wr-rel/inner"),
			"control: a user:// DirAccess walks and makes relative names")
		check(user.change_dir("../".repeat(24) + outside_dir.trim_prefix("/")) != OK, "a relative '../' change_dir does not escape")
		check(not user.file_exists("../".repeat(24) + outside_file.trim_prefix("/")), "a relative '../' file_exists sees nothing")


# No bytes decode into an object, whatever the script asks (decode_variant, every entry to it).
func _get_var() -> void:
	var f := FileAccess.open("user://wr-var.bin", FileAccess.WRITE)
	f.store_var(Gradient.new(), true)
	f.store_var(42)
	f.close()
	f = FileAccess.open("user://wr-var.bin", FileAccess.READ)
	var decoded = f.get_var(true)
	check(not (decoded is Object), "FileAccess.get_var(true) does not decode an object")
	var bytes := var_to_bytes_with_objects(Gradient.new())
	check(not (bytes_to_var_with_objects(bytes) is Object), "bytes_to_var_with_objects does not decode an object")
	check(not (bytes.decode_var(0, true) is Object), "PackedByteArray.decode_var(0, true) does not decode an object")
	check(not (Marshalls.base64_to_variant(Marshalls.raw_to_base64(bytes), true) is Object), "Marshalls.base64_to_variant(…, true) does not decode an object")
	var peer := StreamPeerBuffer.new()
	peer.put_var(Gradient.new(), true)
	peer.seek(0)
	check(not (peer.get_var(true) is Object), "StreamPeerBuffer.get_var(true) does not decode an object")
