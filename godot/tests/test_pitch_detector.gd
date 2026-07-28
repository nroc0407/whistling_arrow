extends SceneTree

const PitchDetectorScript = preload("res://scripts/pitch_detector.gd")

const SAMPLE_RATE: float = 48000.0
const SAMPLE_COUNT: int = 2048
const TEST_AMPLITUDE: float = 0.8

var _failures: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var detector = PitchDetectorScript.new()
	root.add_child(detector)
	await process_frame

	_test_sine(detector, 220.0)
	_test_sine(detector, 440.0)
	_test_sine(detector, 700.0)
	_test_silence(detector)
	_test_command_state(detector)
	_test_capture_resampling(detector)
	await _test_worker_analysis(detector)

	detector.queue_free()
	await process_frame
	if _failures == 0:
		print("PitchDetector tests passed.")
	else:
		printerr("PitchDetector tests failed: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_sine(detector, expected_hz: float) -> void:
	var samples: PackedFloat32Array = _make_sine(expected_hz)
	var result: Dictionary = detector.analyze_samples(samples, SAMPLE_RATE)
	var actual_hz: float = float(result["hz"])
	var tolerance_hz: float = maxf(1.5, expected_hz * 0.01)

	_assert_true(bool(result["voiced"]), "%.0f Hz should be voiced" % expected_hz)
	_assert_near(
		actual_hz,
		expected_hz,
		tolerance_hz,
		"%.0f Hz frequency estimate" % expected_hz
	)
	_assert_true(
		float(result["confidence"]) > 0.90,
		"%.0f Hz should have high confidence" % expected_hz
	)
	_assert_near(
		float(result["rms"]),
		TEST_AMPLITUDE / sqrt(2.0),
		0.02,
		"%.0f Hz RMS" % expected_hz
	)


func _test_silence(detector) -> void:
	var silence := PackedFloat32Array()
	silence.resize(SAMPLE_COUNT)
	silence.fill(0.0)
	var result: Dictionary = detector.analyze_samples(silence, SAMPLE_RATE)

	_assert_true(not bool(result["voiced"]), "silence should not be voiced")
	_assert_near(float(result["hz"]), 0.0, 0.0001, "silence frequency")
	_assert_near(float(result["confidence"]), 0.0, 0.0001, "silence confidence")


func _test_command_state(detector) -> void:
	detector.set_threshold_hz(350.0)
	detector.reset_tracking()

	var result: Dictionary = detector.debug_feed_frequency(220.0)
	_assert_command(result, "float", "return smoothing frame")
	result = detector.debug_feed_frequency(220.0)
	_assert_command(result, "float", "return confirmation frame 1")
	result = detector.debug_feed_frequency(220.0)
	_assert_command(result, "return", "return confirmation frame 2")

	result = detector.debug_feed_frequency(0.0)
	_assert_command(result, "float", "silence immediately floats")

	detector.reset_tracking()
	result = detector.debug_feed_frequency(700.0)
	_assert_command(result, "float", "attack smoothing frame")
	result = detector.debug_feed_frequency(700.0)
	_assert_command(result, "float", "attack confirmation frame 1")
	result = detector.debug_feed_frequency(700.0)
	_assert_command(result, "attack", "attack confirmation frame 2")

	detector.reset_tracking()
	for _frame in range(12):
		result = detector.debug_feed_frequency(350.0)
	_assert_command(result, "float", "threshold dead zone stays floating")


func _test_capture_resampling(detector) -> void:
	var source_count := 3072
	var stereo_samples := PackedVector2Array()
	stereo_samples.resize(source_count)
	for index in source_count:
		var value := TEST_AMPLITUDE * sin(
			TAU * 440.0 * float(index) / SAMPLE_RATE
		)
		stereo_samples[index] = Vector2(value, value)
	var mono_samples: PackedFloat32Array = detector._resample_stereo_to_mono(
		stereo_samples,
		PitchDetectorScript.WINDOW_SIZE
	)
	var effective_rate := (
		SAMPLE_RATE
		* float(PitchDetectorScript.WINDOW_SIZE)
		/ float(source_count)
	)
	var result: Dictionary = detector.analyze_samples(
		mono_samples,
		effective_rate
	)
	_assert_true(bool(result["voiced"]), "resampled 440 Hz should be voiced")
	_assert_near(
		float(result["hz"]),
		440.0,
		6.0,
		"resampled 440 Hz frequency estimate"
	)


func _test_worker_analysis(detector) -> void:
	detector.reset_tracking()
	detector._capture_active = true
	detector._analysis_generation += 1
	detector._pending_capture_samples = _make_sine(440.0)
	detector._pending_capture_rate = SAMPLE_RATE
	detector._start_pending_analysis()

	var deadline := Time.get_ticks_msec() + 2000
	while (
		detector._analysis_task_id != PitchDetectorScript.INVALID_TASK_ID
		and Time.get_ticks_msec() < deadline
	):
		await process_frame
		detector._collect_completed_analysis()

	_assert_true(
		detector._analysis_task_id == PitchDetectorScript.INVALID_TASK_ID,
		"worker pitch task completes and is collected"
	)
	_assert_near(
		detector.raw_hz,
		440.0,
		6.0,
		"worker pitch result reaches main-thread state"
	)
	detector._capture_active = false
	detector._analysis_generation += 1


func _make_sine(frequency_hz: float) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(SAMPLE_COUNT)
	for index in range(SAMPLE_COUNT):
		var phase: float = TAU * frequency_hz * float(index) / SAMPLE_RATE
		samples[index] = TEST_AMPLITUDE * sin(phase)
	return samples


func _assert_near(
	actual: float,
	expected: float,
	tolerance: float,
	label: String
) -> void:
	if absf(actual - expected) <= tolerance:
		return
	_failures += 1
	printerr(
		"FAIL: %s (expected %.4f +/- %.4f, got %.4f)"
		% [label, expected, tolerance, actual]
	)


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % label)


func _assert_command(result: Dictionary, expected: String, label: String) -> void:
	var actual: String = str(result["command"])
	_assert_true(actual == expected, "%s (expected %s, got %s)" % [label, expected, actual])
