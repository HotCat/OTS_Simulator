extends SceneTree

## Convert the useful tail of the captured OTS gait into an indefinitely
## looping, translation-free carrier cycle. The source performance turns over
## time, so the Hips yaw is detrended while its stride-frequency twist remains.
## A symmetric quaternion cross-fade hides the otherwise-visible loop seam.

const SOURCE_LIBRARY := "res://animations/ots_carry_captured.tres"
const SOURCE_ANIMATION := &"ots_carry_captured"
const OUTPUT_LIBRARY := "res://animations/ots_carry_walk_cycle.tres"
const OUTPUT_ANIMATION := &"ots_carry_walk_cycle"
const CLIP_START_SECONDS := 1.24
const CLIP_END_SECONDS := 5.875
const SAMPLE_FPS := 24.0
const SEAM_SEARCH_SECONDS := 1.50
const SEAM_BLEND_SECONDS := 0.125
const HIPS_SUFFIX := ":Hips"
const PHASE_WEIGHTS := {
	"Hips": 1.0,
	"LeftUpperLeg": 2.0,
	"LeftLowerLeg": 3.0,
	"LeftFoot": 4.0,
	"RightUpperLeg": 2.0,
	"RightLowerLeg": 3.0,
	"RightFoot": 4.0,
}


func _initialize() -> void:
	var source_library := load(SOURCE_LIBRARY) as AnimationLibrary
	if source_library == null or not source_library.has_animation(SOURCE_ANIMATION):
		_fail("Cannot load %s/%s" % [SOURCE_LIBRARY, SOURCE_ANIMATION])
		return
	var source := source_library.get_animation(SOURCE_ANIMATION)
	if source == null or source.length <= CLIP_START_SECONDS:
		_fail("Source animation does not extend beyond %.3f seconds" % CLIP_START_SECONDS)
		return

	var requested_end := minf(CLIP_END_SECONDS, source.length)
	var seam_result := _find_phase_aligned_end(source, CLIP_START_SECONDS, requested_end)
	var source_end := float(seam_result.get("time", requested_end))
	var seam_score := float(seam_result.get("score", 0.0))
	var cycle_length := source_end - CLIP_START_SECONDS
	var interval_count := maxi(2, roundi(cycle_length * SAMPLE_FPS))
	var sample_count := interval_count + 1
	var output := Animation.new()
	output.resource_name = str(OUTPUT_ANIMATION)
	output.length = cycle_length
	output.step = 1.0 / SAMPLE_FPS
	output.loop_mode = Animation.LOOP_LINEAR

	for source_track in source.get_track_count():
		if source.track_get_type(source_track) != Animation.TYPE_ROTATION_3D:
			continue
		var values: Array[Quaternion] = []
		for sample_index in sample_count:
			var alpha := float(sample_index) / float(interval_count)
			var source_time := CLIP_START_SECONDS + alpha * cycle_length
			var value := source.rotation_track_interpolate(source_track, source_time).normalized()
			if not values.is_empty() and values[-1].dot(value) < 0.0:
				value = _negated(value)
			values.append(value)

		var track_path := source.track_get_path(source_track)
		if str(track_path).ends_with(HIPS_SUFFIX):
			values = _remove_accumulated_yaw(values)
		_soften_loop_seam(values, cycle_length)

		var output_track := output.add_track(Animation.TYPE_ROTATION_3D)
		output.track_set_path(output_track, track_path)
		output.track_set_interpolation_type(output_track, Animation.INTERPOLATION_LINEAR)
		output.track_set_interpolation_loop_wrap(output_track, true)
		for sample_index in sample_count:
			var output_time := float(sample_index) / float(interval_count) * cycle_length
			output.rotation_track_insert_key(output_track, output_time, values[sample_index])

	output.set_meta("ots_source_library", SOURCE_LIBRARY)
	output.set_meta("ots_source_animation", str(SOURCE_ANIMATION))
	output.set_meta("ots_source_start_seconds", CLIP_START_SECONDS)
	output.set_meta("ots_source_end_seconds", source_end)
	output.set_meta("ots_requested_end_seconds", requested_end)
	output.set_meta("ots_phase_seam_score", seam_score)
	output.set_meta("ots_heading_mode", "detrended_hips_yaw; trajectory owns heading")
	output.set_meta("ots_root_translation", "none; trajectory owns translation")
	output.set_meta("ots_seam_blend_seconds", SEAM_BLEND_SECONDS)
	output.set_meta("ots_sample_fps", SAMPLE_FPS)

	var output_library := AnimationLibrary.new()
	output_library.add_animation(OUTPUT_ANIMATION, output)
	var error := ResourceSaver.save(output_library, OUTPUT_LIBRARY)
	if error != OK:
		_fail("Could not save %s: %s" % [OUTPUT_LIBRARY, error_string(error)])
		return
	print("OTS_WALK_CYCLE_OK source=%.3f..%.3f requested_end=%.3f length=%.3f samples=%d tracks=%d seam=%.3f score=%.6f" % [
		CLIP_START_SECONDS, source_end, requested_end, cycle_length, sample_count,
		output.get_track_count(), SEAM_BLEND_SECONDS, seam_score,
	])
	quit(0)


func _find_phase_aligned_end(source: Animation, start_time: float, requested_end: float) -> Dictionary:
	var delta := 1.0 / SAMPLE_FPS
	var search_start := maxf(start_time + 0.75, requested_end - SEAM_SEARCH_SECONDS)
	var search_end := requested_end - delta
	var weighted_tracks: Array[Dictionary] = []
	for track in source.get_track_count():
		if source.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var path := str(source.track_get_path(track))
		var bone_name := path.get_slice(":", path.get_slice_count(":") - 1)
		var weight := float(PHASE_WEIGHTS.get(bone_name, 0.0))
		if weight > 0.0:
			weighted_tracks.append({"track": track, "weight": weight})
	if weighted_tracks.is_empty() or search_end <= search_start:
		return {"time": requested_end, "score": 0.0}

	var best_time := requested_end
	var best_score := INF
	var candidate_times := PackedFloat32Array()
	var candidate_scores := PackedFloat32Array()
	var candidate_count := floori((search_end - search_start) / delta) + 1
	for candidate_index in candidate_count:
		var candidate := search_start + candidate_index * delta
		var pose_error := 0.0
		var velocity_error := 0.0
		var weight_sum := 0.0
		for item in weighted_tracks:
			var track := int(item.track)
			var weight := float(item.weight)
			var start_pose := source.rotation_track_interpolate(track, start_time).normalized()
			var start_next := source.rotation_track_interpolate(track, start_time + delta).normalized()
			var end_previous := source.rotation_track_interpolate(track, candidate - delta).normalized()
			var end_pose := source.rotation_track_interpolate(track, candidate).normalized()
			pose_error += start_pose.angle_to(end_pose) * weight
			var start_velocity := (start_pose.inverse() * start_next).normalized()
			var end_velocity := (end_previous.inverse() * end_pose).normalized()
			velocity_error += start_velocity.angle_to(end_velocity) * weight
			weight_sum += weight
		var normalized_error := (pose_error + velocity_error * 0.65) / maxf(weight_sum, 0.0001)
		# Prefer a later matching phase when two candidates have similar quality,
		# retaining as much of the user-selected performance as possible.
		var end_distance_penalty := (requested_end - candidate) * 0.002
		var score := normalized_error + end_distance_penalty
		candidate_times.append(candidate)
		candidate_scores.append(score)
		if score < best_score:
			best_score = score
			best_time = candidate
	# Several strides may match the requested start phase. Prefer the latest
	# local minimum whose error is within ten percent of the global best. This
	# retains nearly all of the requested performance without accepting an
	# arbitrary last frame or a non-minimum merely because it is later.
	var accepted_limit := best_score * 1.10 + 0.000001
	for index in range(1, candidate_scores.size() - 1):
		var score := candidate_scores[index]
		if score <= candidate_scores[index - 1] and score <= candidate_scores[index + 1] and score <= accepted_limit:
			best_time = candidate_times[index]
			best_score = score
	return {"time": best_time, "score": best_score}


func _remove_accumulated_yaw(values: Array[Quaternion]) -> Array[Quaternion]:
	if values.size() < 2:
		return values
	var yaw_values: Array[float] = []
	var previous := _twist_yaw(values[0])
	yaw_values.append(previous)
	for index in range(1, values.size()):
		var wrapped := _twist_yaw(values[index])
		previous += wrapf(wrapped - previous, -PI, PI)
		yaw_values.append(previous)
	var drift := yaw_values[-1] - yaw_values[0]
	var result: Array[Quaternion] = []
	for index in values.size():
		var source := values[index]
		var source_twist := _yaw_twist(source)
		var swing := (source * source_twist.inverse()).normalized()
		var alpha := float(index) / float(values.size() - 1)
		var corrected_yaw := yaw_values[index] - drift * alpha
		result.append((swing * Quaternion(Vector3.UP, corrected_yaw)).normalized())
	return result


func _soften_loop_seam(values: Array[Quaternion], cycle_length: float) -> void:
	if values.size() < 3:
		return
	var interval_count := values.size() - 1
	var window := mini(roundi(SEAM_BLEND_SECONDS / cycle_length * interval_count), interval_count / 2)
	window = maxi(window, 1)
	var originals := values.duplicate()
	var first := originals[0] as Quaternion
	var last := originals[-1] as Quaternion
	if first.dot(last) < 0.0:
		last = _negated(last)
	var seam := first.slerp(last, 0.5).normalized()
	var start_correction := (first.inverse() * seam).normalized()
	var end_correction := (last.inverse() * seam).normalized()
	var outgoing_delta := (first.inverse() * (originals[1] as Quaternion)).normalized()
	var incoming_delta := ((originals[-2] as Quaternion).inverse() * last).normalized()
	if outgoing_delta.dot(incoming_delta) < 0.0:
		incoming_delta = _negated(incoming_delta)
	var seam_delta := outgoing_delta.slerp(incoming_delta, 0.5).normalized()
	for offset in range(window + 1):
		var start_index := offset
		var end_index := interval_count - offset
		var distance_alpha := float(offset) / float(window)
		var correction_alpha := smoothstep(0.0, 1.0, distance_alpha)
		var start_fade := start_correction.slerp(Quaternion.IDENTITY, correction_alpha).normalized()
		var end_fade := end_correction.slerp(Quaternion.IDENTITY, correction_alpha).normalized()
		values[start_index] = ((originals[start_index] as Quaternion) * start_fade).normalized()
		values[end_index] = ((originals[end_index] as Quaternion) * end_fade).normalized()
		if offset > 0:
			var tangent_alpha := float(offset - 1) / float(maxi(window - 1, 1))
			var tangent_weight := 1.0 - smoothstep(0.0, 1.0, tangent_alpha)
			var tangent_start := (seam * _quaternion_power(seam_delta, float(offset))).normalized()
			var tangent_end := (seam * _quaternion_power(seam_delta, -float(offset))).normalized()
			values[start_index] = values[start_index].slerp(tangent_start, tangent_weight).normalized()
			values[end_index] = values[end_index].slerp(tangent_end, tangent_weight).normalized()
	# Numerical equality at the wrap boundary avoids even a sub-pixel pop.
	values[-1] = values[0]


func _quaternion_power(value: Quaternion, exponent: float) -> Quaternion:
	var normalized := value.normalized()
	var angle := normalized.get_angle()
	var axis := normalized.get_axis()
	if is_zero_approx(angle) or axis.length_squared() < 0.0000001:
		return Quaternion.IDENTITY
	return Quaternion(axis.normalized(), angle * exponent).normalized()


func _yaw_twist(value: Quaternion) -> Quaternion:
	var twist := Quaternion(0.0, value.y, 0.0, value.w)
	return twist.normalized() if twist.length_squared() > 0.0000001 else Quaternion.IDENTITY


func _twist_yaw(value: Quaternion) -> float:
	var twist := _yaw_twist(value)
	return 2.0 * atan2(twist.y, twist.w)


func _negated(value: Quaternion) -> Quaternion:
	return Quaternion(-value.x, -value.y, -value.z, -value.w)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
