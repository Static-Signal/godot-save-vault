@tool
extends EditorPlugin

## No editor UI - SaveVault is a plain class_name usable from any script.
## This exists so the addon shows up as a real, toggleable entry under
## Project Settings > Plugins, matching what people expect from a Godot
## addon folder.

func _enter_tree() -> void:
	pass

func _exit_tree() -> void:
	pass
