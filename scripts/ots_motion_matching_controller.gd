@tool
extends Node
class_name OTSMotionMatchingController

## Project-local motion-matching-style selector for the OTS carrier.
##
## This is deliberately implemented in GDScript instead of loading the
## upstream native extension.  The native extension that was tested against
## this project targets an older Godot/godot-cpp ABI and caused editor heap
## corruption on Godot 4.7.  This controller keeps the useful part of motion
## matching for the clay-proxy workflow: it evaluates the current route query,
## scores the available gait clips, preserves gait phase, and crossfades when
## the route/load request changes.  CarrierTrajectory remains the owner of
## world translation and heading; this node only selects bone animation.

@export_category("Motion Matching")
@export var enabled := false
@export var auto_select_on_start := true
@export var animation_player_path: NodePath = NodePath("../OTSCarryAnimationPlayer")
@export var trajectory_owner_path: NodePath = NodePath("..")
@export_range(0.05, 2.0, 0.01, "suffix:s") var matching_interval_seconds := 0.18
@export_range(0.0, 1.0, 0.01, "suffix:s") var blend_seconds := 0.16
@export_range(0.0, 1.0, 0.01) var switch_margin := 0.06
@export var preserve_gait_phase := true
@export var restart_trajectory_when_started := true

## Desired load is a normalized request, not a body-weight measurement:
## 0 = ordinary walk, 1 = visibly loaded OTS carry.
@export_range(0.0, 1.0, 0.01) var desired_load := 0.72
@export_range(0.1, 3.0, 0.01, "suffix:m/s") var desired_speed_mps := 0.78
@export_range(0.0, 4.0, 0.01) var speed_weight := 1.0
@export_range(0.0, 4.0, 0.01) var load_weight := 1.2
@export_range(0.0, 4.0, 0.01) var turn_weight := 1.0
@export_range(0.0, 4.0, 0.01) var phase_weight := 0.22
@export_range(0.0, 4.0, 0.01) var clip_penalty_weight := 1.0

## Full AnimationPlayer names include their AnimationLibrary prefix.  The
## baseline clip is never removed or rewritten; it remains the safe fallback.
@export var candidate_animations: Array[StringName] = [
	&"ots_carry_walk_cycle",
	&"h3_heavy_load_hybrid/ots_h3_heavy_load_walk_hybrid",
	&"h3_heavy_load_hybrid_smooth/ots_h3_heavy_load_walk_hybrid_smooth",
]
## Per-candidate profiles correspond by index to candidate_animations.
## These values are intentionally editable because a new gait clip can be
## added without changing the selector algorithm.
@export var candidate_load_profiles: Array[float] = [0.52, 0.82, 0.88]
@export var candidate_speed_profiles: Array[float] = [0.78, 0.76, 0.76]
## Turn cost is a style feature: a lower value favors clips that remain
## visually stable while the predefined route rounds a corner.  It is
## multiplied by the route's normalized turn request, so a straight segment
## does not unfairly punish a clip merely because it has a turn profile.
@export var candidate_turn_profiles: Array[float] = [0.12, 0.90, 0.05]
## Fixed quality/retarget penalties keep the selector from repeatedly choosing
## a known lower-body-only or visibly unstable comparison clip when two clips
## satisfy the physical query equally well.
@export var candidate_selection_penalties: Array[float] = [0.0, 0.12, 0.0]

@export_category("Transport")
@export_tool_button("Enable motion matching")
var enable_action: Callable = enable_motion_matching
@export_tool_button("Disable motion matching")
var disable_action: Callable = disable_motion_matching
@export_tool_button("Select best gait now")
var select_action: Callable = select_best_gait

var _matching_elapsed := 0.0
var _current_animation := StringName()
var _fixed_step_active := false
var _last_score := INF
var _last_query := {}

func _ready() -> void:
	process_priority = 120
	if Engine.is_editor_hint():
		set_process(true)
	if enabled and auto_select_on_start:
		call_deferred("select_best_gait")

func _process(delta: float) -> void:
	if not enabled or _fixed_step_active:
		return
	_matching_elapsed += maxf(delta, 0.0)
	if _matching_elapsed < matching_interval_seconds:
		return
	_matching_elapsed = 0.0
	select_best_gait()

func enable_motion_matching() -> Dictionary:
	enabled = true
	_matching_elapsed = matching_interval_seconds
	select_best_gait()
	return status()

func disable_motion_matching() -> Dictionary:
	enabled = false
	return status()

func start_motion_matching(restart: bool = true) -> Dictionary:
	if restart and restart_trajectory_when_started:
		var owner := _trajectory_owner()
		if owner != null and owner.has_method("restart_carrier_trajectory"):
			owner.call("restart_carrier_trajectory")
	var player := _animation_player()
	if player == null:
		return {"ok": false, "error": "ots_animation_player_not_found"}
	enabled = true
	if restart:
		_current_animation = StringName()
		player.stop()
	select_best_gait()
	if _current_animation.is_empty():
		return {"ok": false, "error": "no_motion_matching_candidate_available"}
	return status()

func editor_capture_begin_fixed_step() -> void:
	_fixed_step_active = true

func editor_capture_step_fixed(_delta: float) -> void:
	if not enabled:
		return
	_matching_elapsed = matching_interval_seconds
	select_best_gait()

func editor_capture_end_fixed_step() -> void:
	_fixed_step_active = false

func status() -> Dictionary:
	return {
		"ok": true,
		"enabled": enabled,
		"animation": str(_current_animation),
		"last_score": _last_score,
		"query": _last_query,
		"desired_load": desired_load,
		"desired_speed_mps": desired_speed_mps,
		"matching_interval_seconds": matching_interval_seconds,
	}

func select_best_gait() -> Dictionary:
	var player := _animation_player()
	if player == null:
		return {"ok": false, "error": "ots_animation_player_not_found"}
	var candidates := _available_candidates(player)
	if candidates.is_empty():
		return {"ok": false, "error": "no_motion_matching_candidate_available"}
	var query := _motion_query()
	_last_query = query
	var current := player.current_animation if not player.current_animation.is_empty() else _current_animation
	var current_score := INF
	var best_name := StringName()
	var best_score := INF
	for item in candidates:
		var score := _score_candidate(item, query)
		if StringName(item.name) == current or StringName(item.name) == _current_animation:
			current_score = score
		if score < best_score:
			best_score = score
			best_name = StringName(item.name)
	if best_name.is_empty():
		return {"ok": false, "error": "motion_matching_score_failed"}
	_last_score = best_score
	# Hysteresis prevents oscillation at a waypoint or when two clips have
	# nearly identical scores.  A currently playing clip is retained unless a
	# new candidate is meaningfully better.
	if not current.is_empty() and current_score < INF and best_name != current:
		if best_score + switch_margin >= current_score:
			best_name = StringName(current)
			best_score = current_score
	if best_name != current and best_name != _current_animation:
		_switch_to(player, best_name)
	else:
		_current_animation = best_name
	return status()

func _switch_to(player: AnimationPlayer, next_name: StringName) -> void:
	var old_name := player.current_animation
	var old_phase := 0.0
	if preserve_gait_phase and not old_name.is_empty() and player.has_animation(old_name):
		var old_animation := player.get_animation(old_name)
		if old_animation != null and old_animation.length > 0.0001:
			old_phase = fposmod(player.current_animation_position / old_animation.length, 1.0)
	var next_animation := player.get_animation(next_name)
	if next_animation == null:
		return
	player.play(next_name, blend_seconds)
	if preserve_gait_phase and next_animation.length > 0.0001:
		player.seek(old_phase * next_animation.length, true)
	_current_animation = next_name

func _available_candidates(player: AnimationPlayer) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in candidate_animations.size():
		var name := candidate_animations[index]
		if not player.has_animation(name):
			continue
		result.append({
			"name": name,
			"load": _profile(candidate_load_profiles, index, 0.5),
			"speed": _profile(candidate_speed_profiles, index, desired_speed_mps),
			"turn": _profile(candidate_turn_profiles, index, 0.5),
			"penalty": _profile(candidate_selection_penalties, index, 0.0),
		})
	return result

func _score_candidate(item: Dictionary, query: Dictionary) -> float:
	var speed_error := absf(float(item.speed) - float(query.get("speed", desired_speed_mps)))
	var load_error := absf(float(item.load) - desired_load)
	var turn_request := clampf(float(query.get("turn", 0.0)), 0.0, 1.0)
	var turn_error := float(item.turn) * turn_request
	var phase_error := 0.0
	var player := _animation_player()
	if player != null and player.has_animation(StringName(item.name)):
		var animation := player.get_animation(StringName(item.name))
		if animation != null and animation.length > 0.0001 and not player.current_animation.is_empty():
			var current_animation := player.get_animation(player.current_animation)
			if current_animation != null and current_animation.length > 0.0001:
				var current_phase := fposmod(player.current_animation_position / current_animation.length, 1.0)
				var candidate_phase := fposmod(player.current_animation_position / animation.length, 1.0)
				phase_error = minf(absf(candidate_phase - current_phase), 1.0 - absf(candidate_phase - current_phase))
	return speed_error * speed_weight + load_error * load_weight + turn_error * turn_weight + phase_error * phase_weight + float(item.penalty) * clip_penalty_weight

func _motion_query() -> Dictionary:
	var owner := _trajectory_owner()
	if owner != null and owner.has_method("get_motion_matching_query"):
		var query = owner.call("get_motion_matching_query")
		if query is Dictionary:
			return query
	return {"speed": desired_speed_mps, "turn": 0.0, "progress": 0.0}

func _animation_player() -> AnimationPlayer:
	return get_node_or_null(animation_player_path) as AnimationPlayer

func _trajectory_owner() -> Node:
	return get_node_or_null(trajectory_owner_path)

func _profile(values: Array[float], index: int, fallback: float) -> float:
	return float(values[index]) if index >= 0 and index < values.size() else fallback
