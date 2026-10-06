extends SceneTree

## Build the preferred H3 comparison clip from two stable sources:
##
## * H3 supplies the lower-body heavy-load timing (hips and legs).
## * ots_carry_walk_cycle supplies the proven torso/head carry pose.
##
## The H3 upper-body capture is intentionally removed rather than smoothed.
## Its arms/torso keys contain the jerk that motivated this comparison, while
## the authored carry pose keeps the hands and shoulder contact coherent.

const SOURCE_LIBRARY := "res://animations/ots_h3_heavy_load_walk_hybrid.tres"
const SOURCE_ANIMATION := &"ots_h3_heavy_load_walk_hybrid"
const BASELINE_LIBRARY := "res://animations/ots_carry_walk_cycle.tres"
const BASELINE_ANIMATION := &"ots_carry_walk_cycle"
const OUTPUT_ANIMATION := &"ots_h3_heavy_load_walk_hybrid_smooth"
const REPLACE_UPPER_BODY_BONES := [
	"Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
]
const BASELINE_TORSO_BONES := ["Spine", "Chest", "UpperChest", "Neck", "Head"]
# Computed from the carrier foot trajectories: frame 6 (0.25 s) minimizes the
# wrap velocity discontinuity while keeping one foot in the planted phase. The
# seam is applied to every track so the lower/upper body phases stay aligned.
const FOOT_CONTACT_SEAM_FRAME := 6


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	var output_path := arguments[0] if not arguments.is_empty() else "res://animations/ots_h3_heavy_load_walk_hybrid_smooth.tres"
	var source_library := load(SOURCE_LIBRARY) as AnimationLibrary
	if source_library == null or not source_library.has_animation(SOURCE_ANIMATION):
		_fail("Missing source hybrid animation")
		return
	var baseline_library := load(BASELINE_LIBRARY) as AnimationLibrary
	if baseline_library == null or not baseline_library.has_animation(BASELINE_ANIMATION):
		_fail("Missing authored baseline animation")
		return
	var source := source_library.get_animation(SOURCE_ANIMATION)
	var baseline := baseline_library.get_animation(BASELINE_ANIMATION)
	var animation := source.duplicate(true) as Animation
	animation.resource_name = str(OUTPUT_ANIMATION)
	# Remove every noisy H3 upper-body track. In particular, do not retain the
	# captured arm tracks: the scene's authored carry pose owns those contacts.
	for track in range(animation.get_track_count() - 1, -1, -1):
		var path := str(animation.track_get_path(track))
		var bone_name := path.get_slice(":", 1)
		if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D and REPLACE_UPPER_BODY_BONES.has(bone_name):
			animation.remove_track(track)
	# Add the stable torso/head tracks from the approved baseline. Their key
	# timing matches the H3 cycle (both are 4.468 s), and the duplicated endpoint
	# preserves the baseline's already-closed seam.
	for track in baseline.get_track_count():
		if baseline.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var path := str(baseline.track_get_path(track))
		var bone_name := path.get_slice(":", 1)
		if not BASELINE_TORSO_BONES.has(bone_name):
			continue
		var output_track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(output_track, baseline.track_get_path(track))
		animation.track_set_interpolation_type(output_track, baseline.track_get_interpolation_type(track))
		animation.track_set_interpolation_loop_wrap(output_track, true)
		for key in baseline.track_get_key_count(track):
			animation.rotation_track_insert_key(
				output_track,
				baseline.track_get_key_time(track, key),
				baseline.track_get_key_value(track, key))
	_relocate_cycle_seam(animation, FOOT_CONTACT_SEAM_FRAME)
	animation.set_meta("ots_cycle_kind", "h3_heavy_load_hybrid_baseline_upper_body")
	animation.set_meta("ots_source_animation", "h3_heavy_load_hybrid/ots_h3_heavy_load_walk_hybrid")
	animation.set_meta("ots_upper_body_source", "ots_carry_walk_cycle/ots_carry_walk_cycle")
	animation.set_meta("ots_upper_body_weights", "baseline authored 1.0; H3 capture 0.0")
	animation.set_meta("ots_upper_body_smoothing", "not applied; authored baseline replaces H3 upper body")
	animation.set_meta("ots_cycle_seam_method", "foot-trajectory velocity discontinuity minimization")
	animation.set_meta("ots_cycle_seam_frame", FOOT_CONTACT_SEAM_FRAME)
	animation.set_meta("ots_cycle_seam_time_seconds", float(FOOT_CONTACT_SEAM_FRAME) * animation.step)
	var library := AnimationLibrary.new()
	var add_error := library.add_animation(OUTPUT_ANIMATION, animation)
	if add_error != OK:
		_fail("AnimationLibrary.add_animation failed: %d" % add_error)
		return
	var save_error := ResourceSaver.save(library, output_path)
	if save_error != OK:
		_fail("ResourceSaver failed for %s: %d" % [output_path, save_error])
		return
	print("H3_HYBRID_SMOOTH_OK tracks=%d length=%.3f output=%s" % [
		animation.get_track_count(), animation.length, output_path,
	])
	quit(0)


func _relocate_cycle_seam(animation: Animation, seam_frame: int) -> void:
	var first_track := -1
	var unique_count := 0
	for track in animation.get_track_count():
		var key_count := animation.track_get_key_count(track)
		if key_count < 2:
			continue
		if first_track < 0:
			first_track = track
			unique_count = key_count - 1
		if key_count - 1 != unique_count:
			push_error("H3_HYBRID_SMOOTH_FAILED: tracks have different sample counts")
			return
	if unique_count <= 1:
		return
	var shift := posmod(seam_frame, unique_count)
	for track in animation.get_track_count():
		var key_count := animation.track_get_key_count(track)
		var values: Array[Variant] = []
		values.resize(unique_count)
		for frame in unique_count:
			values[frame] = animation.track_get_key_value(track, frame)
		for frame in unique_count:
			animation.track_set_key_value(track, frame, values[(shift + frame) % unique_count])
		# The last key is the explicit loop endpoint. It must duplicate the new
		# first sample, otherwise AnimationPlayer interpolation creates a snap.
		animation.track_set_key_value(track, unique_count, values[shift])


func _fail(message: String) -> void:
	push_error("H3_HYBRID_SMOOTH_FAILED: " + message)
	quit(1)
