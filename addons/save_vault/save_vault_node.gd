class_name SaveVaultNode
extends Node

## Thin Node wrapper around SaveVault for people who'd rather configure it
## from the Inspector than write a constructor call. Drop this into an
## autoload (or any always-loaded scene), set the exported fields, and use
## `save_game()`/`load_game()` on this node the same as you'd use them on
## a SaveVault directly - or reach into `vault` for the rest of the API
## (save_exists(), delete_save(), save_async(), ...).
##
## Optional built-in autosave: set autosave_interval_sec above 0 and assign
## get_save_data to a Callable returning the Dictionary to save (this node
## has no idea what your game state looks like, so it has to ask you for
## it each tick of the timer).
##
## save_completed/load_completed are this node's OWN signals (not just
## re-exports) so you can wire them up entirely from the editor's Node
## dock, no script required.

@export var encryption_key: String = ""
@export var save_dir: String = SaveVault.DEFAULT_SAVE_DIR
@export var save_extension: String = ""
@export_enum("json", "binary") var save_format: String = SaveVault.FORMAT_JSON

@export_group("Autosave")
@export_range(0, 3600, 1, "or_greater", "suffix:sec") var autosave_interval_sec: float = 0.0
@export var autosave_slot: int = 0

## Required only if autosave_interval_sec > 0. Assign a Callable returning
## the Dictionary to autosave, e.g.:
##   get_save_data = func(): return {"level": level, "saved_at": Time.get_datetime_string_from_system()}
var get_save_data: Callable

## The underlying SaveVault - use directly for anything not exposed as a
## wrapper method below (save_async(), save_exists(), delete_save(), ...).
var vault: SaveVault

var _autosave_timer: Timer

signal save_completed(slot: int, success: bool)
signal load_completed(slot: int, data: Dictionary)

func _ready() -> void:
	vault = SaveVault.new(encryption_key, save_dir, save_extension, save_format)
	vault.save_completed.connect(func(slot: int, success: bool) -> void: save_completed.emit(slot, success))
	vault.load_completed.connect(func(slot: int, data: Dictionary) -> void: load_completed.emit(slot, data))

	if autosave_interval_sec > 0.0:
		_autosave_timer = Timer.new()
		_autosave_timer.wait_time = autosave_interval_sec
		_autosave_timer.autostart = true
		_autosave_timer.timeout.connect(_on_autosave_timeout)
		add_child(_autosave_timer)

func _on_autosave_timeout() -> void:
	if not get_save_data.is_valid():
		push_warning("[SaveVaultNode] autosave_interval_sec is set but get_save_data was never assigned - skipping")
		return
	vault.save_async(autosave_slot, get_save_data.call())

# ─── Convenience Wrappers (forward straight to `vault`) ───

func save_game(slot: int, data: Dictionary, sync_cloud: bool = true) -> bool:
	return vault.save_game(slot, data, sync_cloud)

func load_game(slot: int) -> Dictionary:
	return vault.load_game(slot)

func save_exists(slot: int) -> bool:
	return vault.save_exists(slot)

func delete_save(slot: int) -> void:
	vault.delete_save(slot)
