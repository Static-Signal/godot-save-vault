extends Node

## Minimal runnable example - run this scene to see a save/load round trip
## in the Output panel. Deletes its own example save on each run so it's
## always starting clean.

func _ready() -> void:
	var vault := SaveVault.new("example-key-change-me")
	vault.save_completed.connect(func(slot: int, success: bool) -> void: print("save_completed: slot %d, success %s" % [slot, success]))
	vault.load_completed.connect(func(slot: int, data: Dictionary) -> void: print("load_completed: slot %d" % slot))

	var data := {
		"level": 3,
		"coins": 120,
		"saved_at": Time.get_datetime_string_from_system(),
	}

	print("Saving: ", data)
	vault.save_game(0, data)

	var loaded: Dictionary = vault.load_game(0)
	print("Loaded: ", loaded)

	vault.delete_save(0)
	print("Cleaned up example save.")
