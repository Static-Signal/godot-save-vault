# Save Vault

Encrypted, multi-slot save/load for Godot 4, with optional Steam Cloud sync and a safe, non-blocking autosave.

Originally built for [Blackdoor](https://blackdoor.tools), a terminal hacking game, and extracted here since the storage layer had nothing game-specific left in it.

## What it does

- **Encrypted local saves** - `FileAccess.open_encrypted_with_pass()` under the hood, with a fallback to plain unencrypted reads (handy if you're adopting this for a project that already had plain-JSON saves).
- **Optional Steam Cloud sync** - works with zero Steam integration at all (falls back to local-only), or syncs to Steam Cloud automatically when the `Steam` singleton (e.g. [GodotSteam](https://godotsteam.com/)) is present.
- **Cloud vs. local conflict resolution** - on load, whichever save is actually newer (by a `saved_at` field you set yourself) wins - a silently-failing Cloud sync can never shadow newer local progress.
- **Safe autosave** - `save_async()` does the encode/encrypt/write on a worker thread so a periodic autosave never causes a frame hitch, and never races an explicit `save_game()` call to the same file.
- **One backup generation** - every save keeps the previous file as a `.bak`, a cheap safety net against a bad write clobbering the only copy of someone's progress.
- **JSON or binary encoding** - pick per-vault. Binary (`var_to_bytes`/`bytes_to_var`) is smaller and a touch faster; JSON is the default and easier to eyeball if you ever decrypt a save by hand while debugging.
- **Save/load signals** - `save_completed(slot, success)` and `load_completed(slot, data)`, if you'd rather react to a signal than check a return value inline.
- **Optional Inspector-configured Node** - `SaveVaultNode` wraps all of the above as `@export` properties plus a built-in autosave timer, for anyone who'd rather not write a constructor call at all.

It's deliberately just the storage layer - you build a plain `Dictionary` from your own game state and hand it over; you get a plain `Dictionary` back to apply however you like. It has no idea what's actually inside your save data.

## Install

Copy `addons/save_vault/` into your project's own `addons/` folder, then enable it under **Project Settings > Plugins** (there's no editor UI - this just registers `SaveVault` as a real plugin entry, the class itself works either way).

## Usage

```gdscript
# Anywhere - an autoload is the natural place if you want global access.
var vault := SaveVault.new("your-own-secret-key-here")

# Save
var data := {"level": 3, "coins": 120, "saved_at": Time.get_datetime_string_from_system()}
vault.save_game(0, data)

# Load
var loaded: Dictionary = vault.load_game(0)
if not loaded.is_empty():
    print("Coins: ", loaded.get("coins", 0))

# Non-blocking autosave (e.g. every few minutes, or on a checkpoint)
vault.save_async(0, data)

# Check / delete
if vault.save_exists(0):
    vault.delete_save(0)
```

See `example/example.gd` for a minimal runnable script.

### No-code setup with SaveVaultNode

Prefer the Inspector over a constructor call? Add a `SaveVaultNode` (an autoload is the natural spot) and set its exported fields - `encryption_key`, `save_dir`, `save_extension`, `save_format` - directly in the editor. It builds the underlying `SaveVault` in `_ready()` and exposes the same `save_game()`/`load_game()` methods, plus its own `save_completed`/`load_completed` signals you can wire up entirely from the Node dock, no script required.

It also has a built-in autosave timer: set `autosave_interval_sec` above `0` and assign `get_save_data` to a `Callable` returning the Dictionary to save -

```gdscript
$SaveVault.get_save_data = func(): return {"level": level, "saved_at": Time.get_datetime_string_from_system()}
```

### Binary format

Pass `"binary"` as the fourth constructor argument (or set `save_format` on `SaveVaultNode`) to encode with `var_to_bytes()`/`bytes_to_var()` instead of JSON:

```gdscript
var vault := SaveVault.new("your-key", SaveVault.DEFAULT_SAVE_DIR, "", SaveVault.FORMAT_BINARY)
```

Leave the extension blank (as above) to get the matching default - `.json` for JSON, `.save` for binary.

### The encryption key

`FileAccess.open_encrypted_with_pass()`'s key isn't a real secret - anyone can pull it out of your exported game's script bytecode. It's just enough to stop a save file from being trivially readable/hand-editable in a text editor, the same threat model that API is actually designed for. Pick your own project-specific string; don't reuse this repo's own example value.

### `saved_at` and the Cloud/local tie-break

Set a `saved_at` field yourself before saving (a timestamp string that sorts correctly, e.g. `Time.get_datetime_string_from_system()`) if you want `load_game()`'s Cloud-vs-local comparison to pick the genuinely newer one. If you never set it, Cloud wins whenever both exist.

## API

| Function | Does |
|---|---|
| `SaveVault.new(encryption_key, save_dir = "user://saves/", save_extension = "", save_format = "json")` | Constructor. Blank `save_extension` picks `.json`/`.save` to match `save_format`. |
| `save_game(slot, data, sync_cloud = true) -> bool` | Synchronous, durable write - use for an explicit save action or before quitting. Emits `save_completed`. |
| `save_async(slot, data) -> void` | Non-blocking autosave (local only, never syncs Cloud, never emits `save_completed` - see its own comment). |
| `load_game(slot) -> Dictionary` | Reads whichever of Cloud/local is newer. Empty dict if neither exists. Emits `load_completed`. |
| `save_exists(slot) -> bool` | Checks Cloud and local. |
| `delete_save(slot) -> void` | Removes local (+ backup) and Cloud copies. |
| `wait_for_pending_autosave() -> void` | Blocks until an in-flight `save_async()` write finishes - `save_game()` already calls this for you. |

**Signals:** `save_completed(slot: int, success: bool)`, `load_completed(slot: int, data: Dictionary)` - fired by `save_game()`/`load_game()` only, not `save_async()`.

`SaveVaultNode` (`save_vault_node.gd`) wraps the same API as a Node with `@export` config - see [No-code setup](#no-code-setup-with-savevaultnode) above.

## License

MIT - see [LICENSE](LICENSE).
