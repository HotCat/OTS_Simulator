@tool
extends RefCounted

## Deterministic G-code-like camera motion in a moving character coordinate.
##
## The confirmed editor camera transform is BASE_RELATIVE: camera transform in
## the tracked character's local space. Program coordinates are absolute
## offsets from that work zero. The caller multiplies the sampled relative
## transform by the character global transform every editor frame.

var segments: Array[Dictionary] = []
var duration_seconds := 0.0
var loop := false
var name := "unnamed_camera_program"
var base_relative := Transform3D.IDENTITY
var final_relative := Transform3D.IDENTITY


func configure(program: Dictionary, confirmed_relative: Transform3D) -> Dictionary:
	segments.clear()
	duration_seconds = 0.0
	base_relative = confirmed_relative
	final_relative = confirmed_relative
	name = str(program.get("name", "unnamed_camera_program"))
	loop = bool(program.get("loop", false))
	var commands_value = program.get("commands", [])
	if not commands_value is Array:
		return {"ok": false, "error": "commands_must_be_array"}
	var current := confirmed_relative
	for command_index in (commands_value as Array).size():
		var command_value = (commands_value as Array)[command_index]
		if not command_value is Dictionary:
			return {"ok": false, "error": "command_must_be_object", "index": command_index}
		var command := command_value as Dictionary
		var compile_result := _compile_command(command, current, command_index)
		if not bool(compile_result.get("ok", false)):
			return compile_result
		var segment := compile_result.get("segment", {}) as Dictionary
		segments.append(segment)
		duration_seconds += float(segment.get("duration", 0.0))
		current = segment.get("end", current) as Transform3D
	final_relative = current
	return {
		"ok": true,
		"name": name,
		"command_count": segments.size(),
		"duration_seconds": duration_seconds,
		"loop": loop,
	}


func sample(time_seconds: float) -> Dictionary:
	if segments.is_empty():
		return {"transform": base_relative, "finished": true, "segment_index": -1}
	var sample_time := maxf(0.0, time_seconds)
	var finished := false
	if duration_seconds <= 0.0:
		return {"transform": final_relative, "finished": true, "segment_index": segments.size() - 1}
	if loop:
		sample_time = fposmod(sample_time, duration_seconds)
	elif sample_time >= duration_seconds:
		sample_time = duration_seconds
		finished = true
	var cursor := 0.0
	for index in segments.size():
		var segment := segments[index]
		var segment_duration := float(segment.get("duration", 0.0))
		if sample_time <= cursor + segment_duration or index == segments.size() - 1:
			var amount := 1.0 if segment_duration <= 0.0 else \
				clampf((sample_time - cursor) / segment_duration, 0.0, 1.0)
			return {
				"transform": _sample_segment(segment, amount),
				"finished": finished,
				"segment_index": index,
				"segment_amount": amount,
			}
		cursor += segment_duration
	return {"transform": final_relative, "finished": true, "segment_index": segments.size() - 1}


func _compile_command(command: Dictionary, start: Transform3D, index: int) -> Dictionary:
	var kind := str(command.get("kind", "")).to_lower()
	if kind in ["g0", "rapid", "g1", "linear", "g5", "bezier"]:
		var target_offset := _vec3(command.get("to"), start.origin - base_relative.origin)
		var end := Transform3D(_target_basis(command, start.basis), base_relative.origin + target_offset)
		var duration := _command_duration(command, start.origin, end.origin, kind == "g0" or kind == "rapid")
		var segment := {
			"kind": "bezier" if kind in ["g5", "bezier"] else "linear",
			"start": start,
			"end": end,
			"duration": duration,
			"easing": str(command.get("easing", "smooth")),
		}
		if kind in ["g5", "bezier"]:
			var delta := end.origin - start.origin
			segment["control1"] = base_relative.origin + _vec3(
				command.get("control1"), start.origin - base_relative.origin + delta / 3.0
			)
			segment["control2"] = base_relative.origin + _vec3(
				command.get("control2"), start.origin - base_relative.origin + delta * 2.0 / 3.0
			)
		return {"ok": true, "segment": segment}
	if kind in ["g2", "g3", "orbit"]:
		var yaw_degrees := float(command.get("yaw_degrees", 0.0))
		if kind == "g2":
			yaw_degrees = -absf(yaw_degrees)
		elif kind == "g3":
			yaw_degrees = absf(yaw_degrees)
		var pitch_degrees := float(command.get("pitch_degrees", 0.0))
		var pivot := _vec3(command.get("pivot"), Vector3(0.0, 1.2, 0.0))
		var segment := {
			"kind": "orbit",
			"start": start,
			"pivot": pivot,
			"yaw_radians": deg_to_rad(yaw_degrees),
			"pitch_radians": deg_to_rad(pitch_degrees),
			"radius_delta": float(command.get("radius_delta", 0.0)),
			"height_delta": float(command.get("height_delta", 0.0)),
			"duration": maxf(0.0, float(command.get("duration", 1.0))),
			"easing": str(command.get("easing", "smooth")),
		}
		segment["end"] = _sample_segment(segment, 1.0)
		return {"ok": true, "segment": segment}
	if kind in ["g4", "dwell"]:
		return {"ok": true, "segment": {
			"kind": "dwell",
			"start": start,
			"end": start,
			"duration": maxf(0.0, float(command.get("duration", 1.0))),
			"easing": "linear",
		}}
	return {"ok": false, "error": "unsupported_camera_command", "index": index, "kind": kind}


func _command_duration(command: Dictionary, from: Vector3, to: Vector3, rapid: bool) -> float:
	if command.has("duration"):
		return maxf(0.0, float(command.get("duration", 0.0)))
	if rapid:
		return 0.0
	var feed_mps := maxf(0.001, float(command.get("feed_mps", 0.5)))
	return from.distance_to(to) / feed_mps


func _target_basis(command: Dictionary, fallback: Basis) -> Basis:
	if not command.has("rotation_degrees"):
		return fallback
	var degrees := _vec3(command.get("rotation_degrees"), Vector3.ZERO)
	var radians := Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z))
	return Basis.from_euler(radians) * base_relative.basis


func _sample_segment(segment: Dictionary, raw_amount: float) -> Transform3D:
	var amount := _ease_amount(raw_amount, str(segment.get("easing", "smooth")))
	var start := segment.get("start", base_relative) as Transform3D
	var end := segment.get("end", start) as Transform3D
	var kind := str(segment.get("kind", "dwell"))
	if kind == "dwell":
		return start
	if kind == "orbit":
		var pivot := segment.get("pivot", Vector3.ZERO) as Vector3
		var yaw := Quaternion(Vector3.UP, float(segment.get("yaw_radians", 0.0)) * amount)
		var pitch_axis := (yaw * start.basis.x).normalized()
		var pitch := Quaternion(pitch_axis, float(segment.get("pitch_radians", 0.0)) * amount)
		var orbit := (pitch * yaw).normalized()
		var arm := start.origin - pivot
		var radius := arm.length()
		if radius > 0.000001:
			arm *= maxf(0.001, radius + float(segment.get("radius_delta", 0.0)) * amount) / radius
		var origin := pivot + orbit * arm + Vector3.UP * float(segment.get("height_delta", 0.0)) * amount
		return Transform3D(Basis(orbit) * start.basis, origin)
	var origin := start.origin.lerp(end.origin, amount)
	if kind == "bezier":
		origin = _cubic_bezier(
			start.origin,
			segment.get("control1", start.origin) as Vector3,
			segment.get("control2", end.origin) as Vector3,
			end.origin,
			amount
		)
	var start_rotation := start.basis.get_rotation_quaternion()
	var end_rotation := end.basis.get_rotation_quaternion()
	return Transform3D(Basis(start_rotation.slerp(end_rotation, amount).normalized()), origin)


func _cubic_bezier(a: Vector3, b: Vector3, c: Vector3, d: Vector3, t: float) -> Vector3:
	var inverse := 1.0 - t
	return inverse * inverse * inverse * a \
		+ 3.0 * inverse * inverse * t * b \
		+ 3.0 * inverse * t * t * c \
		+ t * t * t * d


func _ease_amount(value: float, easing: String) -> float:
	var t := clampf(value, 0.0, 1.0)
	match easing.to_lower():
		"linear":
			return t
		"ease_in":
			return t * t
		"ease_out":
			return 1.0 - (1.0 - t) * (1.0 - t)
		"ease_in_out":
			return 2.0 * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 2.0) / 2.0
		"smoother":
			return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
		_:
			return t * t * (3.0 - 2.0 * t)


func _vec3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback
