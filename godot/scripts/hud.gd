class_name WhistleArrowHUD
extends CanvasLayer

signal start_requested
signal threshold_changed(value: float)

const VIEW_SIZE := Vector2(720.0, 820.0)
const COLOR_TEXT := Color("f7f7fb")
const COLOR_MUTED := Color(0.78, 0.80, 0.88, 0.72)
const COLOR_RED := Color("e53e3e")
const COLOR_BLUE := Color("4a90d9")
const COLOR_GREEN := Color("4ade80")

var _score_label: Label
var _kills_label: Label
var _hp_bar: ProgressBar
var _hp_label: Label
var _pitch_fill: ColorRect
var _pitch_label: Label
var _command_label: Label
var _threshold_slider: HSlider
var _threshold_value: Label
var _status_label: Label
var _overlay: PanelContainer
var _overlay_title: Label
var _overlay_body: Label
var _start_button: Button


func _ready() -> void:
	_build_interface()
	show_intro()


func update_score(value: int) -> void:
	_score_label.text = "Score: %d" % value


func update_kills(value: int) -> void:
	_kills_label.text = "Kills: %d" % value


func update_hp(value: int, maximum: int) -> void:
	_hp_bar.max_value = maximum
	_hp_bar.value = value
	_hp_label.text = "HP %d" % value
	var ratio: float = float(value) / maxf(float(maximum), 1.0)
	var fill_style := _hp_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill_style != null:
		fill_style.bg_color = COLOR_GREEN if ratio > 0.6 else Color("facc15") if ratio > 0.3 else Color("f87171")


func update_pitch(hz: float, confidence: float, command: String) -> void:
	var normalized: float = 0.0
	if hz >= 10.0:
		normalized = clampf(log(hz / 120.0) / log(900.0 / 120.0), 0.0, 1.0)
	var fill_height: float = 112.0 * normalized
	_pitch_fill.position.y = 112.0 - fill_height
	_pitch_fill.size.y = fill_height

	var command_upper := command.to_upper()
	var command_color := Color(0.55, 0.57, 0.64)
	if command == "return":
		command_color = COLOR_BLUE
	elif command == "attack":
		command_color = COLOR_RED
	_pitch_fill.color = command_color
	_command_label.text = command_upper
	_command_label.add_theme_color_override("font_color", command_color)
	_pitch_label.text = (
		"-- Hz" if hz < 10.0
		else "%d Hz · %d%%" % [roundi(hz), roundi(confidence * 100.0)]
	)


func update_capture_state(active: bool, message: String) -> void:
	_status_label.text = ("MIC · " if active else "INPUT · ") + message


func show_intro() -> void:
	_overlay.visible = true
	_overlay_title.text = "WHISTLE ARROW"
	_overlay_body.text = "Low pitch: return  ·  High pitch: attack\nSilence / neutral: float\n\nDebug: 1 return  ·  2 float  ·  3 attack"
	_start_button.text = "Enable Mic & Start"
	_status_label.text = "Press M for mic · Space for debug start"


func show_running() -> void:
	_overlay.visible = false


func show_game_over(final_score: int, final_kills: int) -> void:
	_overlay.visible = true
	_overlay_title.text = "GAME OVER"
	_overlay_body.text = "Final score: %d\nTargets destroyed: %d" % [final_score, final_kills]
	_start_button.text = "Restart"


func get_threshold_hz() -> float:
	return float(_threshold_slider.value)


func _build_interface() -> void:
	var root := Control.new()
	root.name = "HUDRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var title := _make_label("WHISTLE ARROW", Vector2(250, 4), Vector2(220, 24), 15, HORIZONTAL_ALIGNMENT_CENTER)
	title.add_theme_color_override("font_color", Color(1.0, 0.45, 0.2))
	root.add_child(title)

	_score_label = _make_label("Score: 0", Vector2(24, 26), Vector2(160, 30), 18)
	root.add_child(_score_label)
	_kills_label = _make_label("Kills: 0", Vector2(536, 26), Vector2(160, 30), 18, HORIZONTAL_ALIGNMENT_RIGHT)
	root.add_child(_kills_label)

	_hp_bar = ProgressBar.new()
	_hp_bar.position = Vector2(250, 31)
	_hp_bar.size = Vector2(220, 18)
	_hp_bar.min_value = 0
	_hp_bar.max_value = 10
	_hp_bar.value = 10
	_hp_bar.show_percentage = false
	_hp_bar.add_theme_stylebox_override("background", _style_box(Color(1, 1, 1, 0.10), 9))
	_hp_bar.add_theme_stylebox_override("fill", _style_box(COLOR_GREEN, 9))
	root.add_child(_hp_bar)
	_hp_label = _make_label("HP 10", Vector2(250, 27), Vector2(220, 26), 12, HORIZONTAL_ALIGNMENT_CENTER)
	root.add_child(_hp_label)

	_status_label = _make_label("", Vector2(24, 56), Vector2(672, 20), 11, HORIZONTAL_ALIGNMENT_CENTER)
	_status_label.add_theme_color_override("font_color", COLOR_MUTED)
	root.add_child(_status_label)

	var meter_bg := ColorRect.new()
	meter_bg.position = Vector2(680, 350)
	meter_bg.size = Vector2(12, 112)
	meter_bg.color = Color(1, 1, 1, 0.10)
	meter_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(meter_bg)
	_pitch_fill = ColorRect.new()
	_pitch_fill.position = Vector2.ZERO
	_pitch_fill.size = Vector2(12, 0)
	_pitch_fill.color = Color(0.35, 0.36, 0.42)
	_pitch_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meter_bg.add_child(_pitch_fill)
	var meter_caption := _make_label("PITCH", Vector2(661, 326), Vector2(50, 20), 9, HORIZONTAL_ALIGNMENT_CENTER)
	meter_caption.add_theme_color_override("font_color", COLOR_MUTED)
	root.add_child(meter_caption)

	_command_label = _make_label("FLOAT", Vector2(550, 715), Vector2(142, 24), 15, HORIZONTAL_ALIGNMENT_RIGHT)
	root.add_child(_command_label)
	_pitch_label = _make_label("-- Hz", Vector2(500, 738), Vector2(192, 18), 10, HORIZONTAL_ALIGNMENT_RIGHT)
	_pitch_label.add_theme_color_override("font_color", COLOR_MUTED)
	root.add_child(_pitch_label)

	var threshold_label := _make_label("Homing threshold", Vector2(24, 778), Vector2(130, 24), 12)
	threshold_label.add_theme_color_override("font_color", COLOR_MUTED)
	root.add_child(threshold_label)
	_threshold_slider = HSlider.new()
	_threshold_slider.position = Vector2(156, 779)
	_threshold_slider.size = Vector2(430, 24)
	_threshold_slider.min_value = 150
	_threshold_slider.max_value = 900
	_threshold_slider.step = 10
	_threshold_slider.value = 350
	_threshold_slider.value_changed.connect(_on_threshold_value_changed)
	root.add_child(_threshold_slider)
	_threshold_value = _make_label("350 Hz", Vector2(594, 778), Vector2(102, 24), 13, HORIZONTAL_ALIGNMENT_RIGHT)
	_threshold_value.add_theme_color_override("font_color", COLOR_RED)
	root.add_child(_threshold_value)

	_overlay = PanelContainer.new()
	_overlay.position = Vector2(145, 295)
	_overlay.size = Vector2(430, 238)
	_overlay.add_theme_stylebox_override("panel", _style_box(Color(0.035, 0.035, 0.09, 0.94), 18, Color(1, 1, 1, 0.16)))
	root.add_child(_overlay)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	_overlay.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	margin.add_child(stack)
	_overlay_title = Label.new()
	_overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_title.add_theme_font_size_override("font_size", 26)
	_overlay_title.add_theme_color_override("font_color", COLOR_TEXT)
	stack.add_child(_overlay_title)
	_overlay_body = Label.new()
	_overlay_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_body.add_theme_font_size_override("font_size", 13)
	_overlay_body.add_theme_color_override("font_color", COLOR_MUTED)
	stack.add_child(_overlay_body)
	_start_button = Button.new()
	_start_button.text = "Enable Mic & Start"
	_start_button.custom_minimum_size = Vector2(0, 42)
	_start_button.add_theme_font_size_override("font_size", 15)
	_start_button.pressed.connect(func() -> void: start_requested.emit())
	stack.add_child(_start_button)

	update_pitch(0.0, 0.0, "float")


func _make_label(
	text_value: String,
	position_value: Vector2,
	size_value: Vector2,
	font_size: int,
	alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT
) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = position_value
	label.size = size_value
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", COLOR_TEXT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _style_box(
	color: Color,
	radius: int,
	border_color: Color = Color.TRANSPARENT
) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_left = radius
	box.corner_radius_bottom_right = radius
	if border_color.a > 0.0:
		box.border_width_left = 1
		box.border_width_top = 1
		box.border_width_right = 1
		box.border_width_bottom = 1
		box.border_color = border_color
	return box


func _on_threshold_value_changed(value: float) -> void:
	_threshold_value.text = "%d Hz" % roundi(value)
	threshold_changed.emit(value)
