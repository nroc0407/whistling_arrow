class_name GameWorld
extends Node2D

const GameConfig = preload("res://scripts/game_config.gd")

signal score_changed(score: int)
signal hp_changed(hp: int, max_hp: int)
signal kills_changed(kills: int)
signal command_changed(command: String)
signal phase_changed(phase: String)
signal active_enemy_count_changed(count: int)
signal game_started
signal game_over(final_score: int, total_kills: int)

const VALID_COMMANDS := [&"float", &"return", &"attack"]

@export var auto_start: bool = false

var score: int = 0
var hp: int = GameConfig.MAX_HP
var kills: int = 0
var phase: String = "idle"
var current_command: String = "float"

var arrow_position: Vector2 = GameConfig.HOME_POSITION
var arrow_velocity := Vector2(0.0, -2.0)
var arrow_angle: float = -PI / 2.0
var arrow_glow: float = 0.0
var arrow_float_time: float = 0.0
var arrow_trail: Array[Vector2] = []

var enemies: Array[Dictionary] = []
var particles: Array[Dictionary] = []

var _elapsed: float = 0.0
var _damage_flash: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	set_process(true)
	if auto_start:
		start_game()
	else:
		queue_redraw()


func start_game() -> void:
	score = 0
	hp = GameConfig.MAX_HP
	kills = 0
	current_command = "float"
	arrow_position = GameConfig.HOME_POSITION
	arrow_velocity = Vector2(0.0, -2.0)
	arrow_angle = -PI / 2.0
	arrow_glow = 0.0
	arrow_float_time = 0.0
	arrow_trail.clear()
	enemies.clear()
	particles.clear()
	_damage_flash = 0.0
	_set_phase("running")
	_ensure_enemy_count()
	score_changed.emit(score)
	hp_changed.emit(hp, GameConfig.MAX_HP)
	kills_changed.emit(kills)
	command_changed.emit(current_command)
	game_started.emit()
	queue_redraw()


func restart_game() -> void:
	start_game()


func stop_game() -> void:
	current_command = "float"
	_set_phase("idle")
	command_changed.emit(current_command)


func set_command(command: String) -> void:
	var normalized := command.strip_edges().to_lower()
	if StringName(normalized) not in VALID_COMMANDS:
		push_warning("Unknown arrow command: %s" % command)
		return
	if current_command == normalized:
		return
	current_command = normalized
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
	var frame_scale := minf(delta * 60.0, 3.0)
	_damage_flash = maxf(0.0, _damage_flash - 0.04 * frame_scale)
	if is_running():
		_update_arrow(frame_scale)
		_check_arrow_hits()
	_update_enemies(frame_scale)
	_update_particles(frame_scale)
	queue_redraw()


func _update_arrow(frame_scale: float) -> void:
	match current_command:
		"attack":
			var target := _nearest_enemy()
			if not target.is_empty():
				var target_angle: float = (Vector2(target.position) - arrow_position).angle()
				arrow_velocity = _steered_velocity(target_angle, GameConfig.ARROW_ATTACK_TURN * frame_scale, GameConfig.ARROW_ATTACK_SPEED)
			arrow_glow = minf(1.0, arrow_glow + 0.12 * frame_scale)
			arrow_float_time = 0.0
		"return":
			var offset := GameConfig.HOME_POSITION - arrow_position
			var distance := offset.length()
			if distance > GameConfig.ARROW_RETURN_STOP_DISTANCE:
				var speed := minf(GameConfig.ARROW_RETURN_MAX_SPEED, distance * GameConfig.ARROW_RETURN_GAIN)
				arrow_velocity = _steered_velocity(offset.angle(), GameConfig.ARROW_RETURN_TURN * frame_scale, speed)
			else:
				arrow_velocity *= pow(0.7, frame_scale)
			arrow_glow = maxf(0.0, arrow_glow - 0.08 * frame_scale)
			arrow_float_time = 0.0
		_:
			arrow_float_time += frame_scale * 0.04
			arrow_velocity *= pow(0.92, frame_scale)
			arrow_velocity.y += sin(arrow_float_time) * 0.06 * frame_scale
			arrow_velocity.x += cos(arrow_float_time * 0.7) * 0.03 * frame_scale
			arrow_glow = maxf(0.0, arrow_glow - 0.05 * frame_scale)

	arrow_position += arrow_velocity * frame_scale
	arrow_position.x = clampf(arrow_position.x, GameConfig.ARROW_MARGIN, GameConfig.WORLD_SIZE.x - GameConfig.ARROW_MARGIN)
	arrow_position.y = clampf(arrow_position.y, GameConfig.ARROW_MARGIN, GameConfig.WORLD_SIZE.y - GameConfig.ARROW_MARGIN)
	if arrow_velocity.length() > 0.3:
		arrow_angle = arrow_velocity.angle()
	arrow_trail.append(arrow_position)
	if arrow_trail.size() > GameConfig.ARROW_TRAIL_LENGTH:
		arrow_trail.pop_front()


func _steered_velocity(target_angle: float, max_turn: float, speed: float) -> Vector2:
	var current_angle := arrow_angle if arrow_velocity.length_squared() < 0.001 else arrow_velocity.angle()
	var difference := wrapf(target_angle - current_angle, -PI, PI)
	return Vector2.RIGHT.rotated(current_angle + clampf(difference, -max_turn, max_turn)) * speed


func _check_arrow_hits() -> void:
	if current_command != "attack":
		return
	var scored_hit := false
	for enemy in enemies:
		if bool(enemy.hit):
			continue
		if arrow_position.distance_to(Vector2(enemy.position)) < float(enemy.radius) + GameConfig.ARROW_COLLISION_RADIUS:
			enemy.hit = true
			_spawn_particles(Vector2(enemy.position), Color(enemy.color))
			kills += 1
			score += int(round(80.0 * (30.0 / float(enemy.radius))))
			scored_hit = true
	if scored_hit:
		score_changed.emit(score)
		kills_changed.emit(kills)
		_ensure_enemy_count()


func _update_enemies(frame_scale: float) -> void:
	for index in range(enemies.size() - 1, -1, -1):
		var enemy := enemies[index]
		enemy.hit_cooldown = maxf(0.0, float(enemy.hit_cooldown) - GameConfig.ENEMY_COOLDOWN_DECAY * frame_scale)
		if bool(enemy.hit):
			enemy.alpha = float(enemy.alpha) - GameConfig.ENEMY_HIT_FADE * frame_scale
			if float(enemy.alpha) <= 0.0:
				enemies.remove_at(index)
			continue
		if not is_running():
			continue
		var offset := GameConfig.HOME_POSITION - Vector2(enemy.position)
		var distance := offset.length()
		if distance > 0.001:
			enemy.position = Vector2(enemy.position) + offset / distance * GameConfig.ENEMY_SPEED * frame_scale
		if distance < GameConfig.HOME_RADIUS + float(enemy.radius) and float(enemy.hit_cooldown) <= 0.0:
			hp = maxi(0, hp - 1)
			enemy.hit_cooldown = 1.0
			_damage_flash = 1.0
			hp_changed.emit(hp, GameConfig.MAX_HP)
			if hp <= 0:
				_finish_game()
				break
	_ensure_enemy_count()


func _finish_game() -> void:
	if phase == "game_over":
		return
	current_command = "float"
	command_changed.emit(current_command)
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
	while get_active_enemy_count() < GameConfig.MAX_ENEMIES:
		_spawn_enemy()
	var after := get_active_enemy_count()
	if before != after:
		active_enemy_count_changed.emit(after)


func _spawn_enemy() -> void:
	var position := Vector2.ZERO
	match _rng.randi_range(0, 2):
		0:
			position = Vector2(GameConfig.WORLD_SIZE.x * 0.1 + _rng.randf() * GameConfig.WORLD_SIZE.x * 0.8, -40.0)
		1:
			position = Vector2(-40.0, GameConfig.WORLD_SIZE.y * 0.05 + _rng.randf() * GameConfig.WORLD_SIZE.y * 0.6)
		_:
			position = Vector2(GameConfig.WORLD_SIZE.x + 40.0, GameConfig.WORLD_SIZE.y * 0.05 + _rng.randf() * GameConfig.WORLD_SIZE.y * 0.6)
	enemies.append({
		"position": position,
		"radius": GameConfig.ENEMY_MIN_RADIUS + _rng.randf() * GameConfig.ENEMY_RADIUS_RANGE,
		"alpha": 1.0,
		"hit": false,
		"hit_cooldown": 0.0,
		"color": Color.from_hsv(_rng.randf(), 0.7, 0.9),
	})


func _nearest_enemy() -> Dictionary:
	var nearest: Dictionary = {}
	var nearest_distance := INF
	for enemy in enemies:
		if bool(enemy.hit):
			continue
		var distance := arrow_position.distance_squared_to(Vector2(enemy.position))
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = enemy
	return nearest


func _spawn_particles(at: Vector2, color: Color) -> void:
	for ignored in GameConfig.PARTICLES_PER_HIT:
		var angle := _rng.randf() * TAU
		var speed := GameConfig.PARTICLE_MIN_SPEED + _rng.randf() * GameConfig.PARTICLE_SPEED_RANGE
		particles.append({"position": at, "velocity": Vector2.from_angle(angle) * speed, "life": 1.0, "color": color})


func _update_particles(frame_scale: float) -> void:
	for index in range(particles.size() - 1, -1, -1):
		var particle := particles[index]
		particle.position = Vector2(particle.position) + Vector2(particle.velocity) * frame_scale
		var velocity := Vector2(particle.velocity)
		velocity.y += GameConfig.PARTICLE_GRAVITY * frame_scale
		particle.velocity = velocity
		particle.life = float(particle.life) - GameConfig.PARTICLE_FADE * frame_scale
		if float(particle.life) <= 0.0:
			particles.remove_at(index)


func _draw() -> void:
	_draw_background()
	_draw_home()
	for enemy in enemies:
		_draw_target(enemy)
	if is_running() and current_command == "attack":
		_draw_lock_on(_nearest_enemy())
	for particle in particles:
		var color := Color(particle.color)
		color.a *= float(particle.life)
		draw_circle(Vector2(particle.position), 3.5 * float(particle.life), color)
	_draw_trail()
	if is_running():
		_draw_arrow()


func _draw_background() -> void:
	draw_rect(Rect2(Vector2.ZERO, GameConfig.WORLD_SIZE), GameConfig.BACKGROUND_COLOR)
	for index in 70:
		var star := Vector2(fmod(index * 137.5, GameConfig.WORLD_SIZE.x), fmod(index * 91.3, GameConfig.WORLD_SIZE.y))
		draw_circle(star, 0.8, Color(1.0, 1.0, 1.0, 0.2 + (index % 4) * 0.1))
	if _damage_flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, GameConfig.WORLD_SIZE), Color(1.0, 0.0, 0.0, _damage_flash * 0.25))


func _draw_home() -> void:
	for ring in range(10, 0, -1):
		var color := GameConfig.HOME_COLOR
		color.a = 0.025
		draw_circle(GameConfig.HOME_POSITION, GameConfig.HOME_RADIUS * float(ring) / 10.0, color)
	var pulse := 0.5 + 0.5 * sin(_elapsed * 3.0)
	var outline := GameConfig.HOME_COLOR
	outline.a = 0.4 + pulse * 0.3
	draw_arc(GameConfig.HOME_POSITION, GameConfig.HOME_RADIUS, 0.0, TAU, 64, outline, 1.5, true)


func _draw_target(enemy: Dictionary) -> void:
	var center := Vector2(enemy.position)
	var radius := float(enemy.radius)
	var alpha := float(enemy.alpha)
	var colors := [Color(0.90, 0.24, 0.24, alpha), Color(1, 1, 1, alpha), Color(0.90, 0.24, 0.24, alpha), Color(1.0, 0.84, 0.0, alpha)]
	var sizes := [radius, radius * 0.68, radius * 0.42, radius * 0.2]
	for index in 4:
		draw_circle(center, sizes[index], colors[index])
	if float(enemy.hit_cooldown) > 0.0:
		draw_arc(center, radius + 4.0, 0.0, TAU, 48, Color(1, 1, 1, float(enemy.hit_cooldown) * alpha), 3.0, true)


func _draw_trail() -> void:
	for index in range(1, arrow_trail.size()):
		var amount := float(index) / float(arrow_trail.size())
		draw_line(arrow_trail[index - 1], arrow_trail[index], Color(1.0, 0.31, 0.16, amount * 0.65), amount * 4.0, true)


func _draw_arrow() -> void:
	var direction := Vector2.RIGHT.rotated(arrow_angle)
	if arrow_glow > 0.1:
		draw_line(arrow_position - direction * 20.0, arrow_position + direction * 10.0, Color(1.0, 0.31, 0.16, 0.12 * arrow_glow), 14.0 + arrow_glow * 8.0, true)
	draw_line(_arrow_point(Vector2(-24, 0)), _arrow_point(Vector2(12, 0)), GameConfig.ARROW_COLOR, 2.8, true)
	draw_colored_polygon(PackedVector2Array([_arrow_point(Vector2(12, 0)), _arrow_point(Vector2(2, -5)), _arrow_point(Vector2(6, 0)), _arrow_point(Vector2(2, 5))]), GameConfig.ARROW_HEAD_COLOR)
	draw_colored_polygon(PackedVector2Array([_arrow_point(Vector2(-24, 0)), _arrow_point(Vector2(-16, -5)), _arrow_point(Vector2(-16, 5))]), Color(0.53, 0.53, 0.53))


func _arrow_point(local_point: Vector2) -> Vector2:
	return arrow_position + local_point.rotated(arrow_angle)


func _draw_lock_on(target: Dictionary) -> void:
	if target.is_empty():
		return
	var center := Vector2(target.position)
	var radius := float(target.radius)
	var pulse := 0.5 + 0.5 * sin(_elapsed * 8.0)
	draw_arc(center, radius + 10.0 + pulse * 4.0, 0.0, TAU, 64, Color(1.0, 0.31, 0.16, 0.5 + pulse * 0.4), 1.5, true)
	_draw_dashed_line(arrow_position, center, Color(1.0, 0.31, 0.16, 0.1 + pulse * 0.08), 6.0, 6.0)
	var bracket_radius := radius + 14.0
	var bracket_color := Color(1.0, 0.78, 0.20, 0.7 + pulse * 0.3)
	for signs_value in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var signs: Vector2 = signs_value
		var corner: Vector2 = center + signs * bracket_radius
		draw_line(corner - Vector2(0, signs.y * 10.0), corner, bracket_color, 2.0, true)
		draw_line(corner, corner - Vector2(signs.x * 10.0, 0), bracket_color, 2.0, true)


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, dash: float, gap: float) -> void:
	var length := from.distance_to(to)
	if length <= 0.001:
		return
	var direction := (to - from) / length
	var offset := 0.0
	while offset < length:
		draw_line(from + direction * offset, from + direction * minf(offset + dash, length), color, 0.8, true)
		offset += dash + gap
