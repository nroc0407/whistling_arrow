extends Node3D

const PitchDetectorScript = preload("res://scripts/pitch_detector.gd")
const HUDScript = preload("res://scripts/hud.gd")

@onready var world = $GameWorld3D

var _pitch_detector: PitchDetector
var _hud: WhistleArrowHUD
var _debug_mode: bool = false


func _ready() -> void:
	_pitch_detector = PitchDetectorScript.new()
	_pitch_detector.name = "PitchDetector"
	add_child(_pitch_detector)
	_hud = HUDScript.new()
	_hud.name = "HUD"
	add_child(_hud)
	_hud.configure_mode(
		"WHISTLE ARROW // 3D",
		"Numpad 7: pinned target · Numpad 9: origin return"
	)

	_pitch_detector.pitch_updated.connect(_on_pitch_updated)
	_pitch_detector.capture_state_changed.connect(_on_capture_state_changed)
	_hud.start_requested.connect(_start_with_microphone)
	_hud.threshold_changed.connect(_pitch_detector.set_threshold_hz)

	world.score_changed.connect(_hud.update_score)
	world.hp_changed.connect(_hud.update_hp)
	world.kills_changed.connect(_hud.update_kills)
	world.game_started.connect(_on_game_started)
	world.game_over.connect(_on_game_over)
	world.navigation_test_status.connect(_on_navigation_test_status)
	world.set_command("float")
	_hud.update_score(0)
	_hud.update_kills(0)
	_hud.update_hp(10, 10)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	match key_event.keycode:
		KEY_1:
			_set_debug_command("return")
		KEY_2:
			_set_debug_command("float")
		KEY_3:
			_set_debug_command("attack")
		KEY_KP_7:
			_start_navigation_test("target")
		KEY_KP_9:
			_start_navigation_test("origin")
		KEY_M:
			_start_with_microphone()
		KEY_SPACE:
			if not world.is_running():
				_debug_mode = true
				world.start_game()
				world.set_command("float")
				_hud.update_capture_state(
					false,
					"3D debug controls active (1 / 2 / 3)."
				)


func _start_with_microphone() -> void:
	_debug_mode = false
	_pitch_detector.set_threshold_hz(_hud.get_threshold_hz())
	var capture_started: bool = _pitch_detector.start_capture()
	world.start_game()
	world.set_command("float")
	if not capture_started:
		_debug_mode = true
		_hud.update_capture_state(false, "Mic unavailable; use 1 / 2 / 3.")


func _set_debug_command(command: String) -> void:
	_debug_mode = true
	if _pitch_detector.is_capturing():
		_pitch_detector.stop_capture()
	if not world.is_running():
		world.start_game()
	world.set_command(command)
	var display_hz: float = 0.0
	if command == "return":
		display_hz = maxf(120.0, _hud.get_threshold_hz() - 100.0)
	elif command == "attack":
		display_hz = minf(900.0, _hud.get_threshold_hz() + 100.0)
	_hud.update_pitch(
		display_hz,
		1.0 if display_hz > 0.0 else 0.0,
		command
	)
	_hud.update_capture_state(
		false,
		"3D debug command: %s · M returns to mic." % command.to_upper()
	)


func _start_navigation_test(mode: String) -> void:
	_debug_mode = true
	if _pitch_detector.is_capturing():
		_pitch_detector.stop_capture()
	if not world.is_running():
		world.start_game()

	if mode == "target":
		if not world.start_target_navigation_test():
			_hud.update_capture_state(false, "No target available.")
			return
		_hud.update_pitch(
			minf(900.0, _hud.get_threshold_hz() + 100.0),
			1.0,
			"attack"
		)
	else:
		world.start_origin_navigation_test()
		_hud.update_pitch(
			maxf(120.0, _hud.get_threshold_hz() - 100.0),
			1.0,
			"return"
		)


func _on_navigation_test_status(_mode: String, message: String) -> void:
	_hud.update_capture_state(false, message)
	if _mode == "complete":
		_hud.update_pitch(0.0, 0.0, "float")


func _on_pitch_updated(
	hz: float,
	_rms: float,
	confidence: float,
	command: String
) -> void:
	_hud.update_pitch(hz, confidence, command)
	if not _debug_mode:
		world.set_command(command)


func _on_capture_state_changed(active: bool, message: String) -> void:
	_hud.update_capture_state(active, message)


func _on_game_started() -> void:
	_hud.show_running()


func _on_game_over(final_score: int, kills: int) -> void:
	world.set_command("float")
	_hud.show_game_over(final_score, kills)
