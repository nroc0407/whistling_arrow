extends SceneTree

const WorldScript = preload("res://scripts/game_world.gd")
const ConfigScript = preload("res://scripts/game_config.gd")

var _failures: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var world = WorldScript.new()
	root.add_child(world)
	await process_frame

	world.start_game()
	_assert_true(world.is_running(), "world starts in running phase")
	_assert_equal(world.get_active_enemy_count(), 3, "three active targets are maintained")
	_assert_equal(world.hp, ConfigScript.MAX_HP, "HP resets on start")

	world.set_command("attack")
	world.arrow_position = Vector2(world.enemies[0].position)
	world._check_arrow_hits()
	_assert_equal(world.kills, 1, "attack collision scores a kill")
	_assert_equal(world.get_active_enemy_count(), 3, "a replacement target is spawned")

	world.start_game()
	world.hp = 1
	world.enemies[0].position = ConfigScript.HOME_POSITION
	world.enemies[0].hit_cooldown = 0.0
	world._update_enemies(1.0)
	_assert_equal(world.hp, 0, "home collision removes HP")
	_assert_equal(world.phase, "game_over", "zero HP ends the game")

	world.queue_free()
	if _failures == 0:
		print("GameWorld tests passed.")
	else:
		printerr("GameWorld tests failed: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _assert_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		return
	_failures += 1
	printerr("FAIL: %s (expected %s, got %s)" % [label, expected, actual])


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % label)
