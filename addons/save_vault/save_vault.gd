class_name SaveVault
extends RefCounted

## Encrypted, multi-slot save/load with optional Steam Cloud sync and a
## safe, non-blocking autosave - Steam Cloud when available, always an
## encrypted local copy too, whichever is genuinely newer wins on load.
##
## This is intentionally just the storage layer: you build a plain
## Dictionary from your own game state and hand it to save()/save_async(),
## and get a plain Dictionary back from load() to apply however you like.
## It has no idea what's inside your save data.
##
## Usage:
##   var vault := SaveVault.new("your-own-secret-key-here")
##   vault.save(0, {"level": 3, "coins": 120})
##   var data: Dictionary = vault.load(0)
##
## Wrap it in your own autoload singleton if you want global access:
##   # save.gd (an autoload)
##   var vault := SaveVault.new("your-own-secret-key-here")

const DEFAULT_SAVE_DIR := "user://saves/"
const DEFAULT_SAVE_EXTENSION := ".json"

var encryption_key: String
var save_dir: String
var save_extension: String
var steam_available: bool = false

var _save_task_id: int = -1  # in-flight background write from save_async(), see there

func _init(p_encryption_key: String, p_save_dir: String = DEFAULT_SAVE_DIR, p_save_extension: String = DEFAULT_SAVE_EXTENSION) -> void:
	## p_encryption_key is yours to pick - it's what FileAccess.open_encrypted_with_pass()
	## uses to encrypt/decrypt the local save file. It isn't a secret worth
	## real security (anyone can find it in your exported game's script
	## bytecode), it's just enough to keep a save file from being trivially
	## readable/hand-editable in a text editor - the same threat model
	## FileAccess's own encrypted-file API is designed for.
	encryption_key = p_encryption_key
	save_dir = p_save_dir
	save_extension = p_save_extension
	_ensure_save_dir()
	_init_steam()

func _ensure_save_dir() -> void:
	DirAccess.make_dir_recursive_absolute(save_dir)

func _init_steam() -> void:
	## Steam Cloud is entirely optional - everything still works as a plain
	## encrypted local save if the Steam singleton (GodotSteam or similar)
	## isn't present at all, or Cloud is unavailable for this user/session.
	if not Engine.has_singleton("Steam"):
		steam_available = false
		return
	steam_available = true

# ─── File Paths ───

func get_save_path(slot: int) -> String:
	return save_dir + "slot_%d%s" % [slot, save_extension]

func get_steam_filename(slot: int) -> String:
	return "slot_%d%s" % [slot, save_extension]

func get_save_backup_path(slot: int) -> String:
	return get_save_path(slot) + ".bak"

# ─── Save Exists / Delete ───

func save_exists(slot: int) -> bool:
	if steam_available:
		var steam: Object = Engine.get_singleton("Steam")
		if steam.fileExists(get_steam_filename(slot)):
			return true
	return FileAccess.file_exists(get_save_path(slot))

func delete_save(slot: int) -> void:
	## Removes both the local file (and its backup) and the Steam Cloud
	## copy, if either exists. Silent no-op for whichever half doesn't.
	var path: String = get_save_path(slot)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var backup_path: String = get_save_backup_path(slot)
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	if steam_available:
		var steam: Object = Engine.get_singleton("Steam")
		var filename: String = get_steam_filename(slot)
		if steam.fileExists(filename):
			steam.fileDelete(filename)

# ─── Write ───

func write_save(slot: int, data: Dictionary, sync_cloud: bool = true) -> bool:
	## Writes save data as JSON. Steam Cloud if available and sync_cloud is
	## true, always local. steam.fileWrite() blocks the calling thread and
	## its latency depends on network/Steam client state, not just disk
	## speed - sync_cloud lets a periodic autosave skip it so a bad Cloud
	## round-trip can't turn into a periodic hitch; an explicit save/quit
	## should still sync. Unindented JSON - never read by a human anyway
	## (it's encrypted immediately after), so pretty-printing would just
	## make the file bigger for nothing (Steam Cloud has a per-file quota).
	var json_string: String = JSON.stringify(data)
	var success: bool = false

	if steam_available and sync_cloud:
		var steam: Object = Engine.get_singleton("Steam")
		var filename: String = get_steam_filename(slot)
		var byte_data: PackedByteArray = json_string.to_utf8_buffer()
		success = steam.fileWrite(filename, byte_data)
		if not success:
			push_warning("[SaveVault] Steam Cloud save failed, falling back to local")

	# Keep one prior generation before overwriting - a safety net against a
	# stale-save bug silently clobbering the only local copy of newer
	# progress with no way back. Best-effort: a failed backup copy
	# shouldn't block the actual save.
	var save_path: String = get_save_path(slot)
	if FileAccess.file_exists(save_path):
		DirAccess.copy_absolute(save_path, get_save_backup_path(slot))

	var file: FileAccess = FileAccess.open_encrypted_with_pass(save_path, FileAccess.WRITE, encryption_key)
	if not file:
		push_error("[SaveVault] Failed to open local save file for writing: slot %d" % slot)
		return success
	file.store_string(json_string)
	file.close()

	return true

func _write_save_local_only(slot: int, data: Dictionary) -> void:
	## The encode+backup-copy+encrypted-write portion of write_save(), minus
	## Steam Cloud, split out so it can run on a worker thread. Safe as
	## long as `data` is a plain-value snapshot with no live reference back
	## into mutable game state - see save_async()'s own comment.
	var json_string: String = JSON.stringify(data)
	var save_path: String = get_save_path(slot)
	if FileAccess.file_exists(save_path):
		DirAccess.copy_absolute(save_path, get_save_backup_path(slot))
	var file: FileAccess = FileAccess.open_encrypted_with_pass(save_path, FileAccess.WRITE, encryption_key)
	if not file:
		push_error("[SaveVault] Background autosave failed to open local save file for writing: slot %d" % slot)
		return
	file.store_string(json_string)
	file.close()

func save_async(slot: int, data: Dictionary) -> void:
	## Non-blocking autosave: the encode+encrypt+disk-write step moves to a
	## worker thread. Never syncs Steam Cloud (use save() for that, when
	## you genuinely need it durable before e.g. quitting). `data` must be
	## a plain-value snapshot you're done mutating - it's about to be read
	## from a different thread than the one that built it.
	if _save_task_id != -1 and not WorkerThreadPool.is_task_completed(_save_task_id):
		return  # a previous autosave write is still in flight - skip this tick rather than stack a second one
	_save_task_id = WorkerThreadPool.add_task(_write_save_local_only.bind(slot, data))

func wait_for_pending_autosave() -> void:
	## Call before a synchronous save()/quit so it never races an
	## in-flight save_async() write to the same file. Near-instant unless
	## one is still genuinely mid-write.
	if _save_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_save_task_id)

# ─── Read ───

func read_save(slot: int) -> Dictionary:
	## Reads both the Steam Cloud and local copies (when they exist) and
	## returns whichever is actually newer by a "saved_at" field YOU set on
	## your own data before saving (e.g. Time.get_datetime_string_from_system()) -
	## Cloud must never win unconditionally just because it exists. If
	## Cloud writes start silently failing (network, quota, Steam client
	## state) while local writes keep succeeding, a stale-but-readable
	## Cloud file would otherwise shadow newer local progress forever. If
	## you don't set "saved_at" yourself, Cloud wins ties/absence - see
	## _pick_newer_save().
	return _pick_newer_save(_read_cloud_save(slot), _read_local_save(slot))

static func _pick_newer_save(cloud_data: Dictionary, local_data: Dictionary) -> Dictionary:
	## Split out from read_save() so the newer-wins comparison is directly
	## testable without touching Steam or the filesystem.
	if cloud_data.is_empty():
		return local_data
	if local_data.is_empty():
		return cloud_data
	var cloud_saved_at: String = str(cloud_data.get("saved_at", ""))
	var local_saved_at: String = str(local_data.get("saved_at", ""))
	return local_data if local_saved_at > cloud_saved_at else cloud_data

func _read_cloud_save(slot: int) -> Dictionary:
	if not steam_available:
		return {}
	var steam: Object = Engine.get_singleton("Steam")
	var filename: String = get_steam_filename(slot)
	if not steam.fileExists(filename):
		return {}
	var file_data: Dictionary = steam.fileRead(filename, steam.getFileSize(filename))
	if not file_data.get("ret", false):
		return {}
	var json_string: String = file_data.get("buf", PackedByteArray()).get_string_from_utf8()
	return _parse_save_json(json_string, slot)

func _read_local_save(slot: int) -> Dictionary:
	if not FileAccess.file_exists(get_save_path(slot)):
		return {}
	var file: FileAccess = FileAccess.open_encrypted_with_pass(get_save_path(slot), FileAccess.READ, encryption_key)
	if not file:
		# Try unencrypted - lets you adopt this addon for a project that
		# already had plain-JSON saves, or recover from a key change.
		file = FileAccess.open(get_save_path(slot), FileAccess.READ)
		if not file:
			return {}
	var json_string: String = file.get_as_text()
	file.close()
	return _parse_save_json(json_string, slot)

func _parse_save_json(json_string: String, slot: int) -> Dictionary:
	if json_string.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(json_string) != OK:
		push_warning("[SaveVault] Failed to parse save JSON for slot %d" % slot)
		return {}
	if json.data is Dictionary:
		return json.data
	return {}

# ─── Convenience Wrappers ───

func save_game(slot: int, data: Dictionary, sync_cloud: bool = true) -> bool:
	## Synchronous, end to end - use for an explicit "save" action, or on
	## quit/window-close, where you need a guaranteed-durable write before
	## the process might exit, not a fire-and-forget one. Waits out any
	## still-in-flight save_async() write first so the two can't race the
	## same file.
	wait_for_pending_autosave()
	var result: bool = write_save(slot, data, sync_cloud)
	if result:
		print("[SaveVault] Saved slot %d" % slot)
	return result

func load_game(slot: int) -> Dictionary:
	## Reads save data and returns it - applying it to your own game state
	## is on you, same as building it was.
	var data: Dictionary = read_save(slot)
	if data.is_empty():
		push_warning("[SaveVault] No save data found for slot %d" % slot)
	return data
