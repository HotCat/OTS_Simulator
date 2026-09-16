extends Node

## Receives viewport/TCP navigation keys before the GUI focus-navigation pass.
## Releasing the focused control prevents arrow keys from moving the selection
## rectangle between Roll/Pitch/Yaw fields or inserting R/F into an editor.

const VIEWPORT_NAVIGATION_KEYS := [
	KEY_UP,
	KEY_DOWN,
	KEY_LEFT,
	KEY_RIGHT,
	KEY_R,
	KEY_F,
]

func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode not in VIEWPORT_NAVIGATION_KEYS and key_event.physical_keycode not in VIEWPORT_NAVIGATION_KEYS:
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner == null:
		return
	focus_owner.release_focus()
	get_viewport().set_input_as_handled()
