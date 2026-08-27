extends Camera3D

## Runtime inspection camera for the OTS pose demo. Its controls mirror the
## Advanced Locomotion tutorial camera while orbiting a fixed pose target.

@export var target := Vector3(0.0, 1.32, 0.0)
@export_range(1.2, 10.0, 0.1) var distance := 3.1
@export_range(-80.0, 80.0, 0.1, "degrees") var pitch_degrees := 4.2
@export_range(-180.0, 180.0, 0.1, "degrees") var yaw_degrees := 87.0
@export_range(0.05, 1.0, 0.05) var mouse_sensitivity := 0.3
@export_range(0.1, 2.0, 0.1) var zoom_step := 0.35
@export_range(0.05, 1.0, 0.05) var height_step := 0.2

var _initial_target: Vector3
var _initial_distance: float
var _initial_pitch: float
var _initial_yaw: float
var _dragging := false

func _ready() -> void:
	_initial_target = target
	_initial_distance = distance
	_initial_pitch = pitch_degrees
	_initial_yaw = yaw_degrees
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_update_camera()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				_toggle_mouse_capture()
			KEY_R:
				_reset_side_view()
			KEY_EQUAL, KEY_KP_ADD:
				_change_distance(-zoom_step)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_change_distance(zoom_step)
			KEY_PAGEUP:
				target.y += height_step
				_update_camera()
			KEY_PAGEDOWN:
				target.y -= height_step
				_update_camera()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_change_distance(-zoom_step)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_change_distance(zoom_step)
	elif event is InputEventMouseMotion:
		var captured := Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
		if captured or _dragging:
			yaw_degrees = wrapf(yaw_degrees - event.relative.x * mouse_sensitivity, -180.0, 180.0)
			pitch_degrees = clampf(
				pitch_degrees - event.relative.y * mouse_sensitivity,
				-55.0,
				55.0
			)
			_update_camera()

func _change_distance(amount: float) -> void:
	distance = clampf(distance + amount, 1.2, 10.0)
	_update_camera()

func _toggle_mouse_capture() -> void:
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _reset_side_view() -> void:
	target = _initial_target
	distance = _initial_distance
	pitch_degrees = _initial_pitch
	yaw_degrees = _initial_yaw
	_update_camera()

func _update_camera() -> void:
	var yaw := deg_to_rad(yaw_degrees)
	var pitch := deg_to_rad(pitch_degrees)
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * distance
	global_position = target + offset
	look_at(target, Vector3.UP)
