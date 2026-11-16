extends Control

const Validator = preload("res://scripts/adm_validator.gd")
const Preview = preload("res://scripts/adm_preview.gd")

var file_dialog: FileDialog
var save_dialog: FileDialog
var output: RichTextLabel
var selected_report: Dictionary = {}
var diagnostic_toggle: CheckBox
var viewport_container: SubViewportContainer
var viewport: SubViewport
var model_root: Node3D
var camera: Camera3D
var camera_target := Vector3.ZERO
var camera_distance := 3.0
var orbit_yaw := 0.0
var orbit_pitch := 0.15
var dragging := false
var selected_path := ""
var preview_status: Label


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	root.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(root)
	root.add_theme_constant_override("margin_left", 20)
	root.add_theme_constant_override("margin_right", 20)
	root.add_theme_constant_override("margin_top", 20)
	root.add_theme_constant_override("margin_bottom", 20)

	var title := Label.new()
	title.text = "ADM Cross-Engine Showcase — Godot validator"
	title.add_theme_font_size_override("font_size", 24)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "ADM 1.0 · kontejner a metadata · spec SHA: %s" % Validator.SPEC_SHA
	root.add_child(subtitle)

	var controls := HBoxContainer.new()
	root.add_child(controls)
	var open_button := Button.new()
	open_button.text = "Vybrat .adm / .adm_anim"
	open_button.pressed.connect(_open_file_dialog)
	controls.add_child(open_button)
	var save_button := Button.new()
	save_button.text = "Exportovat JSON report"
	save_button.pressed.connect(_save_report)
	controls.add_child(save_button)
	diagnostic_toggle = CheckBox.new()
	diagnostic_toggle.text = "Povolit neúplný diagnostický náhled"
	diagnostic_toggle.tooltip_text = "Neúplný náhled, nikoliv přijetí modelu jako podporovaného."
	diagnostic_toggle.button_pressed = true
	diagnostic_toggle.toggled.connect(_diagnostic_toggled)
	controls.add_child(diagnostic_toggle)

	preview_status = Label.new()
	preview_status.text = "Diagnostický náhled: neúplný, bez animací; není potvrzením kompatibility."
	preview_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(preview_status)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	viewport_container = SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_container.size_flags_stretch_ratio = 2.0
	viewport_container.custom_minimum_size = Vector2(320, 240)
	viewport_container.gui_input.connect(_preview_input)
	split.add_child(viewport_container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_container.add_child(viewport)
	var world := Node3D.new()
	viewport.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	environment.environment.ambient_light_energy = 0.7
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -35, 0)
	world.add_child(light)
	model_root = Node3D.new()
	world.add_child(model_root)
	camera = Camera3D.new()
	camera.current = true
	camera.fov = 45.0
	world.add_child(camera)
	_update_camera()

	output = RichTextLabel.new()
	output.bbcode_enabled = true
	output.fit_content = false
	output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output.custom_minimum_size = Vector2(320, 240)
	output.scroll_following = false
	split.add_child(output)
	_show_placeholder()

	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.adm", "ADM model")
	file_dialog.add_filter("*.adm_anim", "ADM animation library")
	file_dialog.file_selected.connect(_inspect_file)
	add_child(file_dialog)

	save_dialog = FileDialog.new()
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_dialog.add_filter("*.json", "JSON report")
	save_dialog.file_selected.connect(_write_report)
	add_child(save_dialog)


func _open_file_dialog() -> void:
	file_dialog.popup_centered_ratio(0.75)


func _inspect_file(path: String) -> void:
	selected_path = path
	for child in model_root.get_children():
		child.queue_free()
	var loaded: Dictionary = Preview.load_path(path, diagnostic_toggle.button_pressed)
	selected_report = loaded.get("report", {})
	if loaded.has("root"):
		model_root.add_child(loaded.root)
		var bounds: AABB = loaded.bounds
		camera_target = bounds.get_center()
		var radius: float = max(bounds.size.length() * 0.5, 0.05)
		camera_distance = radius * 3.0
		camera.near = max(radius * 0.001, 0.001)
		camera.far = max(radius * 100.0, 100.0)
		_update_camera()
		preview_status.text = "DIAGNOSTICKÝ NÁHLED — neúplný, nejde o potvrzení kompatibility."
		if selected_report.status == "unsupported":
			preview_status.text = "DIAGNOSTICKÝ NÁHLED — povinná rozšíření nepodporována; model není kompatibilní."
	else:
		preview_status.text = "Náhled nedostupný. Viz diagnostika."
		if not selected_report.is_empty() and loaded.has("error"):
			selected_report.preview = {"status": "unavailable", "reason": loaded.error}
	output.clear()
	if loaded.has("error"):
		output.append_text("[b]Náhled nedostupný:[/b] %s\n\n" % loaded.error)
	if selected_report.is_empty():
		return
	output.append_text("[b]Status: %s[/b]\n" % selected_report.status.to_upper())
	output.append_text("Soubor: %s\nSHA-256: %s\n" % [
		selected_report.source, selected_report.assetSha256
	])
	output.append_text("Runtime: %s\n" % selected_report.runtimeStatus.to_upper())
	output.append_text("Specifikace: ADM 1.0 @ %s\n\n" % selected_report.specification.commit)
	output.append_text("[b]Implementované validační schopnosti[/b]\n")
	for capability in selected_report.capabilities.implemented:
		output.append_text("  • %s\n" % capability)
	output.append_text("\n[b]Deklarované schopnosti / rozšíření[/b]\n")
	if selected_report.capabilities.declared.is_empty():
		output.append_text("  (manifest nebyl načten nebo nic nedeklaruje)\n")
	else:
		for capability in selected_report.capabilities.declared:
			output.append_text("  • %s\n" % capability)
	output.append_text("\n[b]Diagnostika[/b]\n")
	for diagnostic in selected_report.diagnostics:
		output.append_text("  • %s\n" % diagnostic)
	for unsupported in selected_report.unsupported:
		output.append_text("  • NEPODPOROVÁNO: %s\n" % unsupported)
	for note in selected_report.capabilities.notes:
		output.append_text("\nOmezení: %s\n" % note)
	for note in selected_report.runtimeLimitations:
		output.append_text("\nNáhled: %s\n" % note)
	if selected_report.has("preview"):
		if selected_report.preview.status == "diagnostic_only":
			output.append_text("\nPrimitiv: %d, vrcholů: %d, trojúhelníků: %d\n" % [
				selected_report.preview.meshPrimitives, selected_report.preview.vertices, selected_report.preview.triangles
			])


func _diagnostic_toggled(_enabled: bool) -> void:
	if not selected_path.is_empty():
		_inspect_file(selected_path)


func _save_report() -> void:
	if selected_report.is_empty():
		output.append_text("\nNejprve vyberte soubor, pro který chcete vytvořit report.\n")
		return
	save_dialog.current_file = selected_report.source.get_basename() + ".report.json"
	save_dialog.popup_centered_ratio(0.65)


func _write_report(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		output.append_text("\nChyba při zápisu reportu: %s\n" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify(selected_report, "\t"))
	file.close()
	output.append_text("\nJSON report uložen: %s\n" % path)


func _show_placeholder() -> void:
	output.append_text("Vyberte libovolný soubor .adm nebo .adm_anim. Výsledek bude označen jako supported, unsupported nebo invalid.\n")
	output.append_text("Náhled je diagnostický, s částečnou podporou materiálů; bez skinningu a animací. Táhnutím myši otáčíte kamerou, kolečkem přibližujete.\n")


func _preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = max(camera_distance * 0.8, camera.near * 2.0)
			_update_camera()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = min(camera_distance * 1.25, camera.far * 0.5)
			_update_camera()
	elif event is InputEventMouseMotion and dragging:
		orbit_yaw -= event.relative.x * 0.01
		orbit_pitch = clamp(orbit_pitch + event.relative.y * 0.01, -1.5, 1.5)
		_update_camera()


func _update_camera() -> void:
	var direction := Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch))
	camera.position = camera_target + direction * camera_distance
	camera.look_at(camera_target, Vector3.UP)
