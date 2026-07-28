class_name GameWorld3D
extends Node3D

const GameConfig3D = preload("res://scripts/game_config_3d.gd")

signal score_changed(score: int)
signal hp_changed(hp: int, max_hp: int)
signal kills_changed(kills: int)
signal command_changed(command: String)
signal phase_changed(phase: String)
signal active_enemy_count_changed(count: int)
signal navigation_test_status(mode: String, message: String)
signal game_started
signal game_over(final_score: int, total_kills: int)

const VALID_COMMANDS := [&"float", &"return", &"attack"]

@export var auto_start: bool = false
@export var random_seed: int = 0

var score: int = 0
var hp: int = GameConfig3D.MAX_HP
var kills: int = 0
var phase: String = "idle"
var current_command: String = "float"
var navigation_test_mode: String = "none"

var arrow_position: Vector3 = GameConfig3D.HOME_POSITION
var arrow_velocity := Vector3(0.0, 0.25, -3.0)
var arrow_float_time: float = 0.0
var arrow_trail: Array[Vector3] = []
var enemies: Array[Dictionary] = []
var _navigation_target: Dictionary = {}
var _follow_through_remaining: float = 0.0

var _elapsed: float = 0.0
var _rng := RandomNumberGenerator.new()
var _arrow_visual: Node3D
var _home_visual: Node3D
var _home_light: OmniLight3D
var _camera: Camera3D
var _lock_on: Node3D
var _trail_instance: MultiMeshInstance3D
var _trail_multimesh: MultiMesh
var _visuals_ready: bool = false


func _ready() -> void:
	if random_seed == 0:
		_rng.randomize()
	else:
		_rng.seed = random_seed
	_build_visuals()
	set_process(true)
	if auto_start:
		start_game()
	else:
		_sync_visuals()


func start_game() -> void:
	score = 0
	hp = GameConfig3D.MAX_HP
	kills = 0
	current_command = "float"
	navigation_test_mode = "none"
	_navigation_target = {}
	_follow_through_remaining = 0.0
	arrow_position = GameConfig3D.HOME_POSITION
	arrow_velocity = Vector3(0.0, 0.25, -3.0)
	arrow_float_time = 0.0
	arrow_trail.clear()
	_clear_enemy_nodes()
	enemies.clear()
	_set_phase("running")
	_ensure_enemy_count()
	score_changed.emit(score)
	hp_changed.emit(hp, GameConfig3D.MAX_HP)
	kills_changed.emit(kills)
	command_changed.emit(current_command)
	game_started.emit()
	_sync_visuals()


func restart_game() -> void:
	start_game()


func stop_game() -> void:
	current_command = "float"
	_set_phase("idle")
	command_changed.emit(current_command)


func set_command(command: String) -> void:
	var normalized := command.strip_edges().to_lower()
	if StringName(normalized) not in VALID_COMMANDS:
		push_warning("Unknown 3D arrow command: %s" % command)
		return
	if navigation_test_mode != "none":
		navigation_test_mode = "none"
		_navigation_target = {}
		_follow_through_remaining = 0.0
		navigation_test_status.emit("none", "Navigation test cancelled.")
	_set_current_command(normalized)


func start_target_navigation_test() -> bool:
	if not is_running():
		start_game()
	var target := _nearest_enemy()
	if target.is_empty():
		navigation_test_status.emit("none", "No target available.")
		return false
	navigation_test_mode = "target"
	_navigation_target = target
	_follow_through_remaining = 0.0
	_set_current_command("attack")
	navigation_test_status.emit(
		"target",
		"Numpad 7 · Pinned target flight."
	)
	return true


func start_origin_navigation_test() -> void:
	if not is_running():
		start_game()
	navigation_test_mode = "origin"
	_navigation_target = {}
	_follow_through_remaining = 0.0
	_set_current_command("return")
	navigation_test_status.emit(
		"origin",
		"Numpad 9 · Returning to the start origin."
	)


func get_navigation_target_position() -> Vector3:
	if (
		navigation_test_mode not in ["target", "pierce"]
		or _navigation_target.is_empty()
	):
		return Vector3.ZERO
	return Vector3(_navigation_target.position)


func _set_current_command(next_command: String) -> void:
	if current_command == next_command:
		return
	current_command = next_command
	command_changed.emit(current_command)


func is_running() -> bool:
	return phase == "running"


func get_active_enemy_count() -> int:
	var count := 0
	for enemy in enemies:
		if not bool(enemy.hit):
			count += 1
	return count


func _process(delta: float) -> void:
	_elapsed += delta
	if is_running():
		_update_arrow(delta)
		_check_arrow_hits()
	_update_enemies(delta)
	_sync_visuals()


func _update_arrow(delta: float) -> void:
	var use_extended_bounds := (
		navigation_test_mode in ["pierce", "recover"]
		or (
			navigation_test_mode == "target"
			and not _is_inside_flight_arena()
		)
	)
	if navigation_test_mode == "target":
		_update_target_navigation_test(delta)
	elif navigation_test_mode == "pierce":
		_update_follow_through(delta)
	elif navigation_test_mode == "recover":
		_update_follow_through_recovery(delta)
	elif navigation_test_mode == "origin":
		_update_origin_navigation_test(delta)
	else:
		_update_command_navigation(delta)

	arrow_position += arrow_velocity * delta
	var horizontal_margin := (
		GameConfig3D.TARGET_FOLLOW_THROUGH_MARGIN
		if use_extended_bounds
		else 0.0
	)
	var vertical_margin := (
		GameConfig3D.TARGET_FOLLOW_THROUGH_VERTICAL_MARGIN
		if use_extended_bounds
		else 0.0
	)
	arrow_position.x = clampf(
		arrow_position.x,
		-GameConfig3D.ARENA_HALF_WIDTH - horizontal_margin,
		GameConfig3D.ARENA_HALF_WIDTH + horizontal_margin
	)
	arrow_position.y = clampf(
		arrow_position.y,
		GameConfig3D.MIN_ALTITUDE - vertical_margin,
		GameConfig3D.MAX_ALTITUDE + vertical_margin
	)
	arrow_position.z = clampf(
		arrow_position.z,
		-GameConfig3D.ARENA_HALF_DEPTH - horizontal_margin,
		GameConfig3D.ARENA_HALF_DEPTH + horizontal_margin
	)
	arrow_trail.append(arrow_position)
	if arrow_trail.size() > GameConfig3D.ARROW_TRAIL_LENGTH:
		arrow_trail.pop_front()


func _update_command_navigation(delta: float) -> void:
	match current_command:
		"attack":
			var target := _nearest_enemy()
			if not target.is_empty():
				var desired_direction: Vector3 = (
					Vector3(target.position) - arrow_position
				).normalized()
				arrow_velocity = _steered_velocity(
					desired_direction,
					GameConfig3D.ARROW_ATTACK_TURN_RATE * delta,
					GameConfig3D.ARROW_ATTACK_SPEED
				)
			arrow_float_time = 0.0
		"return":
			var offset := GameConfig3D.HOME_POSITION - arrow_position
			var distance := offset.length()
			if distance > GameConfig3D.ARROW_RETURN_STOP_DISTANCE:
				var speed := minf(
					GameConfig3D.ARROW_RETURN_MAX_SPEED,
					maxf(1.5, distance * GameConfig3D.ARROW_RETURN_GAIN)
				)
				arrow_velocity = _steered_velocity(
					offset.normalized(),
					GameConfig3D.ARROW_RETURN_TURN_RATE * delta,
					speed
				)
			else:
				arrow_velocity *= exp(-5.0 * delta)
			arrow_float_time = 0.0
		_:
			arrow_float_time += delta
			arrow_velocity *= exp(-1.8 * delta)
			arrow_velocity.y += sin(arrow_float_time * 2.1) * 0.32 * delta
			arrow_velocity.x += cos(arrow_float_time * 0.8) * 0.18 * delta


func _update_target_navigation_test(delta: float) -> void:
	if _navigation_target.is_empty() or bool(_navigation_target.hit):
		_navigation_target = _best_chain_target()
		if _navigation_target.is_empty():
			_complete_navigation_test("No target remains available.")
			return
		navigation_test_status.emit(
			"target",
			"Target refreshed · Continuing chain pursuit."
		)
	var offset := Vector3(_navigation_target.position) - arrow_position
	if offset.length_squared() <= 0.000001:
		return
	arrow_velocity = _steered_velocity(
		offset.normalized(),
		GameConfig3D.ARROW_ATTACK_TURN_RATE * delta,
		GameConfig3D.ARROW_ATTACK_SPEED
	)
	arrow_float_time = 0.0


func _update_origin_navigation_test(delta: float) -> void:
	var offset := GameConfig3D.HOME_POSITION - arrow_position
	var distance := offset.length()
	if distance > GameConfig3D.ARROW_RETURN_STOP_DISTANCE:
		var speed := minf(
			GameConfig3D.ARROW_RETURN_MAX_SPEED,
			maxf(1.5, distance * GameConfig3D.ARROW_RETURN_GAIN)
		)
		arrow_velocity = _steered_velocity(
			offset.normalized(),
			GameConfig3D.ARROW_RETURN_TURN_RATE * delta,
			speed
		)
		return

	arrow_position = arrow_position.lerp(
		GameConfig3D.HOME_POSITION,
		clampf(delta * 6.0, 0.0, 1.0)
	)
	arrow_velocity *= exp(-8.0 * delta)
	if (
		arrow_position.distance_to(GameConfig3D.HOME_POSITION) < 0.08
		and arrow_velocity.length() < 0.15
	):
		arrow_position = GameConfig3D.HOME_POSITION
		arrow_velocity = Vector3.ZERO
		_complete_navigation_test("Origin return complete.")


func _update_follow_through(delta: float) -> void:
	_follow_through_remaining = maxf(
		0.0,
		_follow_through_remaining - delta
	)
	if arrow_velocity.length_squared() > 0.000001:
		var speed := maxf(
			arrow_velocity.length(),
			GameConfig3D.ARROW_ATTACK_SPEED
		)
		arrow_velocity = arrow_velocity.normalized() * speed
	else:
		arrow_velocity = Vector3.FORWARD * GameConfig3D.ARROW_ATTACK_SPEED
	if _follow_through_remaining <= 0.0:
		var chain_target := _navigation_target
		if chain_target.is_empty() or bool(chain_target.hit):
			chain_target = _best_chain_target()
		if not chain_target.is_empty():
			navigation_test_mode = "target"
			_navigation_target = chain_target
			navigation_test_status.emit(
				"target",
				"Chain lock acquired · Continuing to the next target."
			)
			return
		navigation_test_mode = "recover"
		navigation_test_status.emit(
			"recover",
			"Pierce complete · No forward target, curving back."
		)


func _update_follow_through_recovery(delta: float) -> void:
	if _is_inside_flight_arena():
		_complete_navigation_test("Pierce recovery complete.")
		return
	var offset := GameConfig3D.HOME_POSITION - arrow_position
	if offset.length_squared() <= 0.000001:
		_complete_navigation_test("Pierce recovery complete.")
		return
	arrow_velocity = _steered_velocity(
		offset.normalized(),
		GameConfig3D.TARGET_RECOVERY_TURN_RATE * delta,
		GameConfig3D.ARROW_ATTACK_SPEED
	)


func _is_inside_flight_arena() -> bool:
	return (
		absf(arrow_position.x) <= GameConfig3D.ARENA_HALF_WIDTH
		and arrow_position.y >= GameConfig3D.MIN_ALTITUDE
		and arrow_position.y <= GameConfig3D.MAX_ALTITUDE
		and absf(arrow_position.z) <= GameConfig3D.ARENA_HALF_DEPTH
	)


func _steered_velocity(
	desired_direction: Vector3,
	max_turn: float,
	speed: float
) -> Vector3:
	if desired_direction.length_squared() < 0.000001:
		return arrow_velocity
	var current_direction := (
		arrow_velocity.normalized()
		if arrow_velocity.length_squared() > 0.000001
		else Vector3.FORWARD
	)
	var angle := current_direction.angle_to(desired_direction)
	var next_direction := desired_direction
	if angle > max_turn and angle > 0.000001:
		next_direction = current_direction.slerp(
			desired_direction,
			clampf(max_turn / angle, 0.0, 1.0)
		).normalized()
	return next_direction * speed


func _check_arrow_hits() -> void:
	if current_command != "attack":
		return
	var scored_hit := false
	for enemy in enemies:
		if bool(enemy.hit):
			continue
		if (
			arrow_position.distance_to(Vector3(enemy.position))
			< float(enemy.radius) + GameConfig3D.ARROW_COLLISION_RADIUS
		):
			enemy.hit = true
			enemy.alpha = 1.0
			kills += 1
			score += int(round(120.0 / float(enemy.radius)))
			scored_hit = true
	if scored_hit:
		score_changed.emit(score)
		kills_changed.emit(kills)
		_ensure_enemy_count()
		if navigation_test_mode == "target":
			_begin_follow_through()


func _begin_follow_through() -> void:
	navigation_test_mode = "pierce"
	_follow_through_remaining = GameConfig3D.TARGET_FOLLOW_THROUGH_SECONDS
	if arrow_velocity.length_squared() > 0.000001:
		arrow_velocity = (
			arrow_velocity.normalized() * GameConfig3D.ARROW_ATTACK_SPEED
		)
	else:
		arrow_velocity = Vector3.FORWARD * GameConfig3D.ARROW_ATTACK_SPEED
	_navigation_target = _best_chain_target()
	if _navigation_target.is_empty():
		navigation_test_status.emit(
			"pierce",
			"Target pierced · Maintaining follow-through."
		)
	else:
		navigation_test_status.emit(
			"pierce",
			"Target pierced · Next target locked."
		)


func _complete_navigation_test(message: String) -> void:
	navigation_test_mode = "none"
	_navigation_target = {}
	_follow_through_remaining = 0.0
	_set_current_command("float")
	navigation_test_status.emit("complete", message)


func _update_enemies(delta: float) -> void:
	for index in range(enemies.size() - 1, -1, -1):
		var enemy := enemies[index]
		enemy.hit_cooldown = maxf(
			0.0,
			float(enemy.hit_cooldown) - delta
		)
		if bool(enemy.hit):
			enemy.alpha = float(enemy.alpha) - GameConfig3D.ENEMY_HIT_FADE * delta
			if float(enemy.alpha) <= 0.0:
				var hit_node := enemy.get("node") as Node3D
				if is_instance_valid(hit_node):
					hit_node.queue_free()
				enemies.remove_at(index)
			continue
		if not is_running():
			continue

		var offset := GameConfig3D.HOME_POSITION - Vector3(enemy.position)
		var distance := offset.length()
		if distance > 0.001:
			enemy.position = (
				Vector3(enemy.position)
				+ offset / distance * GameConfig3D.ENEMY_SPEED * delta
			)
		if (
			distance < GameConfig3D.HOME_RADIUS + float(enemy.radius)
			and float(enemy.hit_cooldown) <= 0.0
		):
			hp = maxi(0, hp - 1)
			enemy.hit_cooldown = GameConfig3D.ENEMY_DAMAGE_COOLDOWN
			hp_changed.emit(hp, GameConfig3D.MAX_HP)
			if hp <= 0:
				_finish_game()
				break
	_ensure_enemy_count()


func _finish_game() -> void:
	if phase == "game_over":
		return
	navigation_test_mode = "none"
	_navigation_target = {}
	_follow_through_remaining = 0.0
	_set_current_command("float")
	_set_phase("game_over")
	game_over.emit(score, kills)


func _set_phase(next_phase: String) -> void:
	if phase == next_phase:
		return
	phase = next_phase
	phase_changed.emit(phase)


func _ensure_enemy_count() -> void:
	if not is_running():
		return
	var before := get_active_enemy_count()
	while get_active_enemy_count() < GameConfig3D.MAX_ENEMIES:
		_spawn_enemy()
	var after := get_active_enemy_count()
	if before != after:
		active_enemy_count_changed.emit(after)


func _spawn_enemy() -> void:
	var spawn_position := Vector3.ZERO
	var altitude := _rng.randf_range(2.0, 8.5)
	match _rng.randi_range(0, 2):
		0:
			spawn_position = Vector3(
				_rng.randf_range(
					-GameConfig3D.ARENA_HALF_WIDTH * 0.8,
					GameConfig3D.ARENA_HALF_WIDTH * 0.8
				),
				altitude,
				-GameConfig3D.ARENA_HALF_DEPTH
			)
		1:
			spawn_position = Vector3(
				-GameConfig3D.ARENA_HALF_WIDTH,
				altitude,
				_rng.randf_range(-GameConfig3D.ARENA_HALF_DEPTH, 4.0)
			)
		_:
			spawn_position = Vector3(
				GameConfig3D.ARENA_HALF_WIDTH,
				altitude,
				_rng.randf_range(-GameConfig3D.ARENA_HALF_DEPTH, 4.0)
			)

	var color := Color.from_hsv(_rng.randf(), 0.68, 0.95)
	var radius := (
		GameConfig3D.ENEMY_MIN_RADIUS
		+ _rng.randf() * GameConfig3D.ENEMY_RADIUS_RANGE
	)
	var enemy_node := _create_enemy_visual(radius, color)
	enemy_node.position = spawn_position
	add_child(enemy_node)
	enemies.append({
		"position": spawn_position,
		"radius": radius,
		"alpha": 1.0,
		"hit": false,
		"hit_cooldown": 0.0,
		"color": color,
		"node": enemy_node,
	})


func _nearest_enemy() -> Dictionary:
	var nearest: Dictionary = {}
	var nearest_distance := INF
	for enemy in enemies:
		if bool(enemy.hit):
			continue
		var distance := arrow_position.distance_squared_to(
			Vector3(enemy.position)
		)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = enemy
	return nearest


func _best_chain_target() -> Dictionary:
	var current_direction := (
		arrow_velocity.normalized()
		if arrow_velocity.length_squared() > 0.000001
		else Vector3.FORWARD
	)
	var best_target: Dictionary = {}
	var best_score := INF
	for enemy in enemies:
		if bool(enemy.hit):
			continue
		var offset := Vector3(enemy.position) - arrow_position
		var distance := offset.length()
		if distance <= 0.000001:
			continue
		var turn_angle := current_direction.angle_to(offset / distance)
		var score_value := (
			turn_angle
			+ distance * GameConfig3D.TARGET_CHAIN_DISTANCE_WEIGHT
		)
		if score_value < best_score:
			best_score = score_value
			best_target = enemy
	return best_target


func _clear_enemy_nodes() -> void:
	for enemy in enemies:
		var enemy_node := enemy.get("node") as Node3D
		if is_instance_valid(enemy_node):
			enemy_node.queue_free()


func _build_visuals() -> void:
	_build_environment()
	_build_arena()
	_build_home()
	_build_arrow()
	_build_lock_on()
	_visuals_ready = true


func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = GameConfig3D.BACKGROUND_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.28, 0.34, 0.56)
	environment.ambient_light_energy = 0.75
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)

	var key_light := DirectionalLight3D.new()
	key_light.name = "KeyLight"
	key_light.rotation_degrees = Vector3(-48.0, -28.0, 0.0)
	key_light.light_color = Color(0.72, 0.82, 1.0)
	key_light.light_energy = 1.45
	key_light.shadow_enabled = false
	add_child(key_light)

	_camera = Camera3D.new()
	_camera.name = "ArenaCamera"
	_camera.position = Vector3(0.0, 17.0, 26.0)
	_camera.fov = 52.0
	_camera.current = true
	add_child(_camera)
	_camera.look_at(Vector3(0.0, 3.0, -1.5), Vector3.UP)


func _build_arena() -> void:
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(
		GameConfig3D.ARENA_HALF_WIDTH * 2.2,
		GameConfig3D.ARENA_HALF_DEPTH * 2.2
	)
	var floor_instance := MeshInstance3D.new()
	floor_instance.name = "ArenaFloor"
	floor_instance.mesh = floor_mesh
	floor_instance.material_override = _make_material(
		GameConfig3D.FLOOR_COLOR,
		0.08
	)
	floor_instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(floor_instance)

	var grid_material := _make_material(GameConfig3D.GRID_COLOR, 0.65, true)
	grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var grid_mesh := ImmediateMesh.new()
	grid_mesh.surface_begin(Mesh.PRIMITIVE_LINES, grid_material)
	for x_value in range(-14, 15, 2):
		grid_mesh.surface_add_vertex(
			Vector3(float(x_value), 0.015, -GameConfig3D.ARENA_HALF_DEPTH)
		)
		grid_mesh.surface_add_vertex(
			Vector3(float(x_value), 0.015, GameConfig3D.ARENA_HALF_DEPTH)
		)
	for z_value in range(-16, 17, 2):
		grid_mesh.surface_add_vertex(
			Vector3(-GameConfig3D.ARENA_HALF_WIDTH, 0.016, float(z_value))
		)
		grid_mesh.surface_add_vertex(
			Vector3(GameConfig3D.ARENA_HALF_WIDTH, 0.016, float(z_value))
		)
	grid_mesh.surface_end()
	var grid_instance := MeshInstance3D.new()
	grid_instance.name = "ArenaGrid"
	grid_instance.mesh = grid_mesh
	grid_instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(grid_instance)


func _build_home() -> void:
	_home_visual = Node3D.new()
	_home_visual.name = "HomeBeacon"
	_home_visual.position = GameConfig3D.HOME_POSITION
	add_child(_home_visual)

	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = GameConfig3D.HOME_RADIUS
	base_mesh.bottom_radius = GameConfig3D.HOME_RADIUS * 1.15
	base_mesh.height = 0.22
	var base := MeshInstance3D.new()
	base.mesh = base_mesh
	base.material_override = _make_material(GameConfig3D.HOME_COLOR, 2.2)
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_home_visual.add_child(base)

	for ring_index in 3:
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = 0.82 + ring_index * 0.35
		ring_mesh.outer_radius = 0.9 + ring_index * 0.35
		var ring := MeshInstance3D.new()
		ring.mesh = ring_mesh
		ring.position.y = 0.14 + ring_index * 0.08
		ring.material_override = _make_material(
			GameConfig3D.HOME_COLOR,
			1.8,
			true
		)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_home_visual.add_child(ring)

	_home_light = OmniLight3D.new()
	_home_light.light_color = GameConfig3D.HOME_COLOR
	_home_light.light_energy = 3.2
	_home_light.omni_range = 8.0
	_home_visual.add_child(_home_light)


func _build_arrow() -> void:
	_arrow_visual = Node3D.new()
	_arrow_visual.name = "Arrow"
	add_child(_arrow_visual)

	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.09
	shaft_mesh.bottom_radius = 0.09
	shaft_mesh.height = 2.4
	var shaft := MeshInstance3D.new()
	shaft.mesh = shaft_mesh
	shaft.rotation_degrees.x = 90.0
	shaft.material_override = _make_material(
		GameConfig3D.ARROW_COLOR,
		1.6
	)
	_arrow_visual.add_child(shaft)

	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.34
	head_mesh.height = 0.72
	var head := MeshInstance3D.new()
	head.mesh = head_mesh
	head.position.z = -1.42
	head.rotation_degrees.x = -90.0
	head.material_override = _make_material(
		GameConfig3D.ARROW_HEAD_COLOR,
		2.4
	)
	_arrow_visual.add_child(head)

	var fletch_material := _make_material(Color(0.72, 0.76, 0.88), 0.4)
	for rotation_value in [0.0, 90.0]:
		var fletch_mesh := BoxMesh.new()
		fletch_mesh.size = Vector3(0.62, 0.035, 0.52)
		var fletch := MeshInstance3D.new()
		fletch.mesh = fletch_mesh
		fletch.position.z = 1.05
		fletch.rotation_degrees.z = rotation_value
		fletch.material_override = fletch_material
		_arrow_visual.add_child(fletch)

	var trail_mesh := SphereMesh.new()
	trail_mesh.radius = 0.11
	trail_mesh.height = 0.22
	var trail_material := _make_material(
		GameConfig3D.ARROW_HEAD_COLOR,
		2.0,
		true
	)
	_trail_multimesh = MultiMesh.new()
	_trail_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_trail_multimesh.instance_count = GameConfig3D.ARROW_TRAIL_LENGTH
	_trail_multimesh.mesh = trail_mesh
	_trail_instance = MultiMeshInstance3D.new()
	_trail_instance.name = "ArrowTrail"
	_trail_instance.multimesh = _trail_multimesh
	_trail_instance.material_override = trail_material
	_trail_instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	_trail_instance.visible = false
	add_child(_trail_instance)
	for trail_index in GameConfig3D.ARROW_TRAIL_LENGTH:
		_trail_multimesh.set_instance_transform(
			trail_index,
			Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3.ZERO)
		)


func _build_lock_on() -> void:
	_lock_on = Node3D.new()
	_lock_on.name = "LockOn"
	_lock_on.visible = false
	add_child(_lock_on)
	var lock_material := _make_material(
		GameConfig3D.LOCK_COLOR,
		2.5,
		true
	)
	for rotation_value in [Vector3.ZERO, Vector3(90.0, 0.0, 0.0)]:
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = 0.76
		ring_mesh.outer_radius = 0.84
		var ring := MeshInstance3D.new()
		ring.mesh = ring_mesh
		ring.rotation_degrees = rotation_value
		ring.material_override = lock_material
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_lock_on.add_child(ring)


func _create_enemy_visual(radius: float, color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Target"
	var body_mesh := SphereMesh.new()
	body_mesh.radius = radius
	body_mesh.height = radius * 2.0
	var body := MeshInstance3D.new()
	body.mesh = body_mesh
	body.material_override = _make_material(color, 1.25)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(body)

	var core_mesh := SphereMesh.new()
	core_mesh.radius = radius * 0.32
	core_mesh.height = radius * 0.64
	var core := MeshInstance3D.new()
	core.mesh = core_mesh
	core.material_override = _make_material(Color.WHITE, 2.3)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(core)
	return root


func _make_material(
	color: Color,
	emission_strength: float = 0.0,
	transparent: bool = false
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.28
	material.roughness = 0.42
	if emission_strength > 0.0:
		material.emission_enabled = true
		material.emission = Color(color.r, color.g, color.b)
		material.emission_energy_multiplier = emission_strength
	if transparent or color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _sync_visuals() -> void:
	if not _visuals_ready:
		return
	_arrow_visual.position = arrow_position
	if arrow_velocity.length_squared() > 0.001:
		var direction := arrow_velocity.normalized()
		var up := Vector3.UP
		if absf(direction.dot(up)) > 0.98:
			up = Vector3.FORWARD
		_arrow_visual.look_at(arrow_position + direction, up)

	for enemy in enemies:
		var enemy_node := enemy.get("node") as Node3D
		if not is_instance_valid(enemy_node):
			continue
		enemy_node.position = Vector3(enemy.position)
		var scale_value := maxf(0.01, float(enemy.alpha))
		enemy_node.scale = Vector3.ONE * scale_value

	_trail_instance.visible = is_running()
	for trail_index in GameConfig3D.ARROW_TRAIL_LENGTH:
		if trail_index < arrow_trail.size():
			var amount := float(trail_index + 1) / float(
				GameConfig3D.ARROW_TRAIL_LENGTH
			)
			var trail_basis := Basis.IDENTITY.scaled(
				Vector3.ONE * maxf(0.18, amount)
			)
			_trail_multimesh.set_instance_transform(
				trail_index,
				Transform3D(trail_basis, arrow_trail[trail_index])
			)
		else:
			_trail_multimesh.set_instance_transform(
				trail_index,
				Transform3D(
					Basis.IDENTITY.scaled(Vector3.ONE * 0.001),
					arrow_position
				)
			)

	var target := (
		_navigation_target
		if (
			navigation_test_mode in ["target", "pierce"]
			and not _navigation_target.is_empty()
		)
		else _nearest_enemy()
	)
	_lock_on.visible = (
		is_running()
		and current_command == "attack"
		and navigation_test_mode != "recover"
		and not target.is_empty()
	)
	if _lock_on.visible:
		_lock_on.position = Vector3(target.position)
		var lock_scale := (float(target.radius) + 0.45) / 0.84
		_lock_on.scale = Vector3.ONE * lock_scale
		_lock_on.rotation.y = _elapsed * 2.6
		_lock_on.rotation.x = sin(_elapsed * 1.7) * 0.35

	var home_pulse := 1.0 + sin(_elapsed * 3.0) * 0.06
	_home_visual.scale = Vector3.ONE * home_pulse
	_home_light.light_energy = 3.2 + sin(_elapsed * 3.0) * 0.7
