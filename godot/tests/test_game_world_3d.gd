extends SceneTree

const WorldScript = preload("res://scripts/game_world_3d.gd")
const ConfigScript = preload("res://scripts/game_config_3d.gd")

var _failures: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var world = WorldScript.new()
	world.random_seed = 42
	root.add_child(world)
	await process_frame

	world.start_game()
	_assert_true(world.is_running(), "3D world starts in running phase")
	_assert_equal(
		world.get_active_enemy_count(),
		ConfigScript.MAX_ENEMIES,
		"three active 3D targets are maintained"
	)
	_assert_equal(world.hp, ConfigScript.MAX_HP, "3D HP resets on start")

	world.set_command("attack")
	world.arrow_position = Vector3(world.enemies[0].position)
	world._check_arrow_hits()
	_assert_equal(world.kills, 1, "3D attack collision scores a kill")
	_assert_equal(
		world.get_active_enemy_count(),
		ConfigScript.MAX_ENEMIES,
		"a replacement 3D target is spawned"
	)

	world.arrow_position = Vector3(
		ConfigScript.ARENA_HALF_WIDTH + 10.0,
		ConfigScript.MAX_ALTITUDE + 10.0,
		ConfigScript.ARENA_HALF_DEPTH + 10.0
	)
	world._update_arrow(0.1)
	_assert_true(
		world.arrow_position.x <= ConfigScript.ARENA_HALF_WIDTH
		and world.arrow_position.y <= ConfigScript.MAX_ALTITUDE
		and world.arrow_position.z <= ConfigScript.ARENA_HALF_DEPTH,
		"3D arrow remains inside arena bounds"
	)

	world.start_game()
	world.hp = 1
	world.enemies[0].position = ConfigScript.HOME_POSITION
	world.enemies[0].hit_cooldown = 0.0
	world._update_enemies(0.0)
	_assert_equal(world.hp, 0, "3D home collision removes HP")
	_assert_equal(world.phase, "game_over", "zero 3D HP ends the game")

	world.start_game()
	world.enemies[0].position = Vector3(0.0, 4.0, 0.0)
	world.enemies[1].position = Vector3(14.0, 4.0, 0.0)
	world.enemies[2].position = Vector3(-12.0, 7.0, -12.0)
	var pinned_target: Dictionary = world._nearest_enemy()
	var pinned_position := Vector3(pinned_target.position)
	var chained_position := Vector3(world.enemies[1].position)
	_assert_true(
		world.start_target_navigation_test(),
		"numpad target navigation test starts"
	)
	_assert_equal(
		world.navigation_test_mode,
		"target",
		"target navigation mode is active"
	)
	_assert_true(
		world.get_navigation_target_position().is_equal_approx(pinned_position),
		"target navigation pins the selected target"
	)
	world.arrow_position = pinned_position
	world.arrow_velocity = Vector3(1.0, 0.0, 0.0)
	world._check_arrow_hits()
	_assert_equal(
		world.navigation_test_mode,
		"pierce",
		"target navigation enters follow-through on arrival"
	)
	_assert_equal(
		world.current_command,
		"attack",
		"target navigation remains attacking during follow-through"
	)
	_assert_true(
		not world.get_navigation_target_position().is_zero_approx(),
		"next target is reserved immediately after a pierce"
	)
	world._sync_visuals()
	_assert_true(
		world._lock_on.visible,
		"reserved chain target is visibly locked during follow-through"
	)
	var pierced_position: Vector3 = world.arrow_position
	world._update_arrow(0.25)
	_assert_true(
		world.arrow_position.distance_to(pierced_position) > 2.0,
		"arrow keeps meaningful speed after piercing a target"
	)
	for _chain_lock_step in 8:
		world._update_arrow(0.1)
		if world.navigation_test_mode == "target":
			break
	_assert_equal(
		world.navigation_test_mode,
		"target",
		"follow-through automatically locks a forward target"
	)
	_assert_true(
		world.get_navigation_target_position().is_equal_approx(
			chained_position
		),
		"chain targeting selects the low-turn-cost forward target"
	)
	_assert_equal(
		world.current_command,
		"attack",
		"chain targeting remains in attack"
	)
	var chain_distance_before: float = world.arrow_position.distance_to(
		chained_position
	)
	world._update_arrow(0.1)
	_assert_true(
		world.arrow_position.distance_to(chained_position)
		< chain_distance_before,
		"chain targeting curves toward the next target"
	)

	world.arrow_position = chained_position
	world.arrow_velocity = Vector3(1.0, 0.0, 0.0)
	world._check_arrow_hits()
	_assert_equal(
		world.navigation_test_mode,
		"pierce",
		"the chained target starts another follow-through"
	)
	var behind_offset := 10.0
	for enemy in world.enemies:
		if bool(enemy.hit):
			continue
		enemy.position = (
			world.arrow_position
			+ Vector3(-behind_offset, 0.0, 0.0)
		)
		behind_offset += 3.0
	_assert_true(
		not world._best_chain_target().is_empty(),
		"chain selection accepts the best target behind the arrow"
	)
	for _rear_chain_step in 8:
		world._update_arrow(0.1)
		if world.navigation_test_mode == "target":
			break
	_assert_equal(
		world.navigation_test_mode,
		"target",
		"follow-through continues to a rear target instead of ending"
	)
	_assert_equal(
		world.current_command,
		"attack",
		"rear target refresh keeps the chain attacking"
	)
	_assert_true(
		world.arrow_velocity.length() > 1.0,
		"arrow preserves momentum when starting the next turn"
	)
	world.set_command("float")

	world.start_game()
	world.arrow_position = Vector3(8.0, 6.0, -5.0)
	var origin_distance_before: float = world.arrow_position.distance_to(
		ConfigScript.HOME_POSITION
	)
	world.start_origin_navigation_test()
	for _navigation_step in 20:
		world._update_arrow(0.1)
	_assert_true(
		world.arrow_position.distance_to(ConfigScript.HOME_POSITION)
		< origin_distance_before,
		"origin navigation moves toward the start position"
	)
	world.arrow_position = ConfigScript.HOME_POSITION
	world.arrow_velocity = Vector3.ZERO
	world._update_arrow(0.1)
	_assert_equal(
		world.navigation_test_mode,
		"none",
		"origin navigation completes at the start position"
	)
	_assert_equal(
		world.current_command,
		"float",
		"origin navigation floats after arrival"
	)

	world.queue_free()
	if _failures == 0:
		print("GameWorld3D tests passed.")
	else:
		printerr("GameWorld3D tests failed: %d" % _failures)
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
