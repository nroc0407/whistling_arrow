class_name PitchDetector
extends Node

## Captures microphone audio and turns whistle pitch into one of three commands.
##
## Call [method start_capture] from a button/key event. In a web export that call
## must happen after a browser user gesture so the microphone permission prompt is
## allowed. The project must also enable `audio/driver/enable_input`.

signal pitch_updated(hz: float, rms: float, confidence: float, command: String)
signal command_changed(command: String)
signal capture_state_changed(active: bool, message: String)

const WINDOW_SIZE: int = 1024
const TARGET_SAMPLE_RATE: float = 16000.0
const CAPTURE_BUFFER_SECONDS: float = 0.12
const INVALID_TASK_ID: int = -1
const MIN_HZ: float = 120.0
const MAX_HZ: float = 900.0
const RMS_MIN: float = 0.003
const CONFIDENCE_MIN: float = 0.46
const NEUTRAL_GAP_MIN: float = 25.0
const NEUTRAL_GAP_RATIO: float = 0.075
const SMOOTH_KEEP: float = 0.62
const SMOOTH_NEW: float = 0.38
const SILENCE_DECAY: float = 0.18
const CONFIRM_FRAMES: int = 2
const FIRST_PEAK_RATIO: float = 0.90

@export_range(150.0, 900.0, 1.0) var mark_hz: float = 350.0
@export var capture_bus_name: StringName = &"PitchCapture"

var raw_hz: float = 0.0
var smooth_hz: float = 0.0
var pitch_rms: float = 0.0
var pitch_confidence: float = 0.0
var current_command: String = "float"

var _pending_command: String = "float"
var _pending_frames: int = 0
var _capture_active: bool = false
var _capture: AudioEffectCapture
var _microphone_player: AudioStreamPlayer
var _sample_rate: float = 48000.0
var _owns_capture_bus: bool = false
var _added_capture_effect: bool = false
var _analysis_task_id: int = INVALID_TASK_ID
var _analysis_generation: int = 0
var _analysis_result: Dictionary = {}
var _analysis_result_mutex := Mutex.new()
var _pending_capture_samples := PackedFloat32Array()
var _pending_capture_rate: float = TARGET_SAMPLE_RATE


func _process(_delta: float) -> void:
	_collect_completed_analysis()
	if not _capture_active or _capture == null:
		return
	_capture_latest_window()
	_start_pending_analysis()


## Starts microphone capture. This deliberately is not called from `_ready()` so
## web builds can invoke it from a user gesture.
func start_capture() -> bool:
	if _capture_active:
		return true

	var input_enabled: bool = bool(
		ProjectSettings.get_setting("audio/driver/enable_input", false)
	)
	if not input_enabled:
		var setting_message := "Enable Audio > Driver > Enable Input before capturing."
		push_warning(setting_message)
		capture_state_changed.emit(false, setting_message)
		return false

	if not _ensure_capture_pipeline():
		var setup_message := "Could not create the microphone capture pipeline."
		push_error(setup_message)
		capture_state_changed.emit(false, setup_message)
		return false

	_capture.clear_buffer()
	_sample_rate = float(AudioServer.get_mix_rate())
	_analysis_generation += 1
	_pending_capture_samples = PackedFloat32Array()
	_clear_analysis_result()
	_microphone_player.play()
	_capture_active = true
	var started_message := "Microphone capture started."
	if OS.has_feature("web"):
		started_message = "Microphone capture started; browser permission may be pending."
	capture_state_changed.emit(true, started_message)
	return true


func stop_capture() -> void:
	if _microphone_player != null and _microphone_player.playing:
		_microphone_player.stop()
	if _capture != null:
		_capture.clear_buffer()

	var was_active: bool = _capture_active
	_capture_active = false
	_analysis_generation += 1
	_pending_capture_samples = PackedFloat32Array()
	reset_tracking(true)
	if was_active:
		capture_state_changed.emit(false, "Microphone capture stopped.")


func is_capturing() -> bool:
	return _capture_active


func set_threshold_hz(value: float) -> void:
	mark_hz = clampf(value, 150.0, 900.0)


func _capture_latest_window() -> void:
	var source_window_size := _get_source_window_size()
	var available := _capture.get_frames_available()
	if available < source_window_size:
		return

	# Drop everything except the newest complete window. This prevents stale
	# microphone input from creating a burst of expensive analysis tasks.
	var discard_count := available - source_window_size
	if discard_count > 0:
		_capture.get_buffer(discard_count)

	var stereo_samples := _capture.get_buffer(source_window_size)
	if stereo_samples.size() != source_window_size:
		return
	_pending_capture_samples = _resample_stereo_to_mono(
		stereo_samples,
		WINDOW_SIZE
	)
	_pending_capture_rate = (
		_sample_rate * float(WINDOW_SIZE) / float(source_window_size)
	)


func _get_source_window_size() -> int:
	if _sample_rate <= TARGET_SAMPLE_RATE:
		return WINDOW_SIZE
	return ceili(float(WINDOW_SIZE) * _sample_rate / TARGET_SAMPLE_RATE)


func _resample_stereo_to_mono(
	stereo_samples: PackedVector2Array,
	output_size: int
) -> PackedFloat32Array:
	var mono_samples := PackedFloat32Array()
	if stereo_samples.is_empty() or output_size <= 0:
		return mono_samples
	mono_samples.resize(output_size)
	if output_size == 1 or stereo_samples.size() == 1:
		var first := stereo_samples[0]
		mono_samples[0] = (first.x + first.y) * 0.5
		return mono_samples

	var position_scale := (
		float(stereo_samples.size() - 1) / float(output_size - 1)
	)
	for output_index in output_size:
		var source_position := float(output_index) * position_scale
		var left_index := int(floor(source_position))
		var right_index := mini(left_index + 1, stereo_samples.size() - 1)
		var blend := source_position - float(left_index)
		var left_frame := stereo_samples[left_index]
		var right_frame := stereo_samples[right_index]
		var left_value := (left_frame.x + left_frame.y) * 0.5
		var right_value := (right_frame.x + right_frame.y) * 0.5
		mono_samples[output_index] = lerpf(left_value, right_value, blend)
	return mono_samples


func _start_pending_analysis() -> void:
	if (
		_analysis_task_id != INVALID_TASK_ID
		or _pending_capture_samples.is_empty()
	):
		return
	var samples := _pending_capture_samples
	var sample_rate := _pending_capture_rate
	var generation := _analysis_generation
	_pending_capture_samples = PackedFloat32Array()
	_analysis_task_id = WorkerThreadPool.add_task(
		_run_capture_analysis.bind(samples, sample_rate, generation),
		false,
		"Whistle pitch analysis"
	)


func _run_capture_analysis(
	samples: PackedFloat32Array,
	sample_rate: float,
	generation: int
) -> void:
	var analysis := analyze_samples(samples, sample_rate)
	_analysis_result_mutex.lock()
	_analysis_result = {
		"generation": generation,
		"analysis": analysis,
	}
	_analysis_result_mutex.unlock()


func _collect_completed_analysis() -> void:
	if (
		_analysis_task_id == INVALID_TASK_ID
		or not WorkerThreadPool.is_task_completed(_analysis_task_id)
	):
		return

	var completed_task := _analysis_task_id
	_analysis_task_id = INVALID_TASK_ID
	var wait_error := WorkerThreadPool.wait_for_task_completion(completed_task)
	var result := _take_analysis_result()
	if (
		wait_error != OK
		or not _capture_active
		or int(result.get("generation", -1)) != _analysis_generation
	):
		return
	var analysis: Dictionary = result.get("analysis", {})
	if analysis.is_empty():
		return
	_apply_detection(
		float(analysis["hz"]),
		float(analysis["rms"]),
		float(analysis["confidence"])
	)


func _take_analysis_result() -> Dictionary:
	_analysis_result_mutex.lock()
	var result := _analysis_result
	_analysis_result = {}
	_analysis_result_mutex.unlock()
	return result


func _clear_analysis_result() -> void:
	_analysis_result_mutex.lock()
	_analysis_result = {}
	_analysis_result_mutex.unlock()


## Pure pitch analysis: no signals and no smoothing/command state are changed.
## The input normally contains exactly [constant WINDOW_SIZE] mono samples.
func analyze_samples(samples: PackedFloat32Array, sample_rate: float) -> Dictionary:
	var sample_count: int = mini(samples.size(), WINDOW_SIZE)
	if sample_count < 8 or sample_rate <= 0.0:
		return _empty_analysis()

	var mean: float = 0.0
	for index in range(sample_count):
		mean += samples[index]
	mean /= float(sample_count)

	var centered := PackedFloat32Array()
	centered.resize(sample_count)
	var energy: float = 0.0
	for index in range(sample_count):
		var value: float = samples[index] - mean
		centered[index] = value
		energy += value * value

	var rms: float = sqrt(energy / float(sample_count))
	if rms < RMS_MIN:
		return {
			"hz": 0.0,
			"rms": rms,
			"confidence": 0.0,
			"voiced": false,
			"period": 0.0,
		}

	var min_period: int = maxi(2, int(floor(sample_rate / MAX_HZ)))
	var max_period: int = mini(sample_count - 2, int(floor(sample_rate / MIN_HZ)))
	if min_period > max_period:
		return {
			"hz": 0.0,
			"rms": rms,
			"confidence": 0.0,
			"voiced": false,
			"period": 0.0,
		}

	var correlations := PackedFloat32Array()
	correlations.resize(max_period + 1)
	correlations.fill(-1.0)

	var best_period: int = -1
	var best_confidence: float = -1.0
	for period in range(min_period, max_period + 1):
		var correlation: float = _normalized_correlation(centered, period)
		correlations[period] = correlation
		if correlation > best_confidence:
			best_confidence = correlation
			best_period = period

	if best_period < 0 or best_confidence < CONFIDENCE_MIN:
		return {
			"hz": 0.0,
			"rms": rms,
			"confidence": maxf(best_confidence, 0.0),
			"voiced": false,
			"period": 0.0,
		}

	# A sinusoid also correlates at 2x, 3x, ... its period. Selecting the first
	# strong local peak prevents those later peaks from being reported as octave
	# subharmonics (notably a 700 Hz tone being mistaken for about 350 Hz).
	var selected_period: int = best_period
	var strong_peak_floor: float = maxf(
		CONFIDENCE_MIN,
		best_confidence * FIRST_PEAK_RATIO
	)
	for period in range(min_period + 1, max_period):
		var center: float = correlations[period]
		if (
			center >= strong_peak_floor
			and center >= correlations[period - 1]
			and center > correlations[period + 1]
		):
			selected_period = period
			break

	var selected_confidence: float = correlations[selected_period]
	var refined_period: float = float(selected_period)
	if selected_period > min_period and selected_period < max_period:
		var left: float = correlations[selected_period - 1]
		var center: float = correlations[selected_period]
		var right: float = correlations[selected_period + 1]
		var denominator: float = left - 2.0 * center + right
		if absf(denominator) > 0.000001:
			var offset: float = 0.5 * (left - right) / denominator
			refined_period += clampf(offset, -1.0, 1.0)

	var detected_hz: float = sample_rate / refined_period
	var voiced: bool = (
		selected_confidence >= CONFIDENCE_MIN
		and detected_hz >= MIN_HZ
		and detected_hz <= MAX_HZ
	)
	if not voiced:
		detected_hz = 0.0

	return {
		"hz": detected_hz,
		"rms": rms,
		"confidence": maxf(selected_confidence, 0.0),
		"voiced": voiced,
		"period": refined_period if voiced else 0.0,
	}


## Runs pure analysis and then updates smoothing, command confirmation, and signals.
func process_samples(samples: PackedFloat32Array, sample_rate: float) -> Dictionary:
	var analysis: Dictionary = analyze_samples(samples, sample_rate)
	return _apply_detection(
		float(analysis["hz"]),
		float(analysis["rms"]),
		float(analysis["confidence"])
	)


## Allows keyboard/test controls to drive exactly the same command state machine.
func debug_feed_frequency(hz: float) -> Dictionary:
	var valid_hz: float = hz if hz >= MIN_HZ and hz <= MAX_HZ else 0.0
	var debug_rms: float = 1.0 if valid_hz > 0.0 else 0.0
	var debug_confidence: float = 1.0 if valid_hz > 0.0 else 0.0
	return _apply_detection(valid_hz, debug_rms, debug_confidence)


func reset_tracking(emit_update: bool = false) -> void:
	var previous_command: String = current_command
	raw_hz = 0.0
	smooth_hz = 0.0
	pitch_rms = 0.0
	pitch_confidence = 0.0
	current_command = "float"
	_pending_command = "float"
	_pending_frames = 0
	if emit_update:
		if previous_command != current_command:
			command_changed.emit(current_command)
		pitch_updated.emit(0.0, 0.0, 0.0, current_command)


func _apply_detection(hz: float, rms: float, confidence: float) -> Dictionary:
	raw_hz = hz
	pitch_rms = rms
	pitch_confidence = confidence

	if hz > 0.0 and confidence >= CONFIDENCE_MIN:
		smooth_hz = smooth_hz * SMOOTH_KEEP + hz * SMOOTH_NEW
	else:
		smooth_hz *= SILENCE_DECAY
	if smooth_hz < 10.0:
		smooth_hz = 0.0

	var gap: float = maxf(NEUTRAL_GAP_MIN, mark_hz * NEUTRAL_GAP_RATIO)
	var low_max: float = mark_hz - gap
	var high_min: float = mark_hz + gap
	var next_command: String = "float"
	if hz > 0.0 and confidence >= CONFIDENCE_MIN:
		if smooth_hz >= MIN_HZ and smooth_hz <= low_max:
			next_command = "return"
		elif smooth_hz >= high_min:
			next_command = "attack"

	var previous_command: String = current_command
	if next_command == "float":
		current_command = "float"
		_pending_command = "float"
		_pending_frames = 0
	else:
		if next_command == _pending_command:
			_pending_frames += 1
		else:
			_pending_command = next_command
			_pending_frames = 1
		if _pending_frames >= CONFIRM_FRAMES:
			current_command = next_command

	if current_command != previous_command:
		command_changed.emit(current_command)
	pitch_updated.emit(smooth_hz, pitch_rms, pitch_confidence, current_command)

	return {
		"hz": raw_hz,
		"smooth_hz": smooth_hz,
		"rms": pitch_rms,
		"confidence": pitch_confidence,
		"voiced": raw_hz > 0.0 and pitch_confidence >= CONFIDENCE_MIN,
		"command": current_command,
	}


func _normalized_correlation(samples: PackedFloat32Array, period: int) -> float:
	var cross_energy: float = 0.0
	var left_energy: float = 0.0
	var right_energy: float = 0.0
	var limit: int = samples.size() - period
	for index in range(limit):
		var left: float = samples[index]
		var right: float = samples[index + period]
		cross_energy += left * right
		left_energy += left * left
		right_energy += right * right

	var denominator: float = sqrt(left_energy * right_energy)
	if denominator <= 0.000000001:
		return 0.0
	return cross_energy / denominator


func _empty_analysis() -> Dictionary:
	return {
		"hz": 0.0,
		"rms": 0.0,
		"confidence": 0.0,
		"voiced": false,
		"period": 0.0,
	}


func _ensure_capture_pipeline() -> bool:
	if _capture != null and _microphone_player != null:
		return true

	var bus_index: int = AudioServer.get_bus_index(capture_bus_name)
	if bus_index < 0:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, capture_bus_name)
		_owns_capture_bus = true

	AudioServer.set_bus_mute(bus_index, true)
	for effect_index in range(AudioServer.get_bus_effect_count(bus_index)):
		var effect: AudioEffect = AudioServer.get_bus_effect(bus_index, effect_index)
		if effect is AudioEffectCapture:
			_capture = effect as AudioEffectCapture
			break

	if _capture == null:
		_capture = AudioEffectCapture.new()
		_capture.buffer_length = CAPTURE_BUFFER_SECONDS
		AudioServer.add_bus_effect(bus_index, _capture, 0)
		_added_capture_effect = true

	if _microphone_player == null:
		_microphone_player = AudioStreamPlayer.new()
		_microphone_player.name = "MicrophonePlayer"
		_microphone_player.stream = AudioStreamMicrophone.new()
		_microphone_player.bus = capture_bus_name
		add_child(_microphone_player)

	return _capture != null and _microphone_player != null


func _exit_tree() -> void:
	if _microphone_player != null and _microphone_player.playing:
		_microphone_player.stop()
	_capture_active = false
	_analysis_generation += 1
	_pending_capture_samples = PackedFloat32Array()
	if _analysis_task_id != INVALID_TASK_ID:
		WorkerThreadPool.wait_for_task_completion(_analysis_task_id)
		_analysis_task_id = INVALID_TASK_ID
	_clear_analysis_result()

	var bus_index: int = AudioServer.get_bus_index(capture_bus_name)
	if _owns_capture_bus and bus_index >= 0:
		AudioServer.remove_bus(bus_index)
	elif _added_capture_effect and bus_index >= 0 and _capture != null:
		for effect_index in range(AudioServer.get_bus_effect_count(bus_index)):
			if AudioServer.get_bus_effect(bus_index, effect_index) == _capture:
				AudioServer.remove_bus_effect(bus_index, effect_index)
				break
