extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var ui: Control = load("res://scenes/main.tscn").instantiate()
	root.add_child(ui)
	await process_frame
	if not ui.diagnostic_toggle.button_pressed:
		push_error("Diagnostic preview must be available by default.")
		quit(1)
		return
	ui._inspect_file(ProjectSettings.globalize_path("res://ADM/humanoid.adm"))
	if ui.selected_report.status != "unsupported" or not ui.selected_report.has("preview") or ui.selected_report.preview.status != "diagnostic_only":
		push_error("Humanoid diagnostic preview did not load.")
		quit(1)
		return
	if not ui.selected_report.preview.diagnosticOverride or not ui.preview_status.text.contains("nepodporována"):
		push_error("Required-extension warning or diagnostic status was not displayed.")
		quit(1)
		return
	var textured := 0
	for material in ui.selected_report.preview.materials:
		if material.baseColorTexture == "png_jpeg":
			textured += 1
		if material.shaderSupported or not material.shaderFallbackActive:
			push_error("Partial material fallback must not claim full shader support.")
			quit(1)
			return
	if textured != 3:
		push_error("Expected three textured humanoid materials, got %d." % textured)
		quit(1)
		return
	ui.diagnostic_toggle.button_pressed = false
	await process_frame
	if ui.selected_report.status != "unsupported" or ui.selected_report.preview.status != "unavailable" or ui.model_root.get_child_count() != 0:
		push_error("Disabling diagnostic mode must hide the unsupported model and record why.")
		quit(1)
		return
	ui.diagnostic_toggle.button_pressed = true
	await process_frame
	if ui.selected_report.status != "unsupported" or ui.selected_report.preview.status != "diagnostic_only" or ui.model_root.get_child_count() != 1:
		push_error("Re-enabling diagnostic mode must reload the selected model.")
		quit(1)
		return
	for index in range(10):
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = ui.viewport.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Renderer did not produce a preview image.")
		quit(1)
		return
	var corner := image.get_pixel(0, 0)
	var different := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var pixel := image.get_pixel(x, y)
			if abs(pixel.r - corner.r) + abs(pixel.g - corner.g) + abs(pixel.b - corner.b) > 0.1:
				different += 1
	if different < 50:
		push_error("Preview image contains too few pixels different from its background: %d." % different)
		quit(1)
		return
	var path := ProjectSettings.globalize_path("res://reports/humanoid-preview.png")
	var error := image.save_png(path)
	if error != OK:
		push_error("Cannot save preview image: %s" % error_string(error))
		quit(1)
		return
	var report_file := FileAccess.open("res://reports/humanoid-ui-test.json", FileAccess.WRITE)
	if report_file == null:
		push_error("Cannot write UI test report: %s" % error_string(FileAccess.get_open_error()))
		quit(1)
		return
	var report := {
		"reportType": "Humanoid diagnostic preview UI test",
		"assetSha256": ui.selected_report.assetSha256,
		"specification": ui.selected_report.specification,
		"engineVersion": Engine.get_version_info().string,
		"capabilities": ui.selected_report.capabilities,
		"validationStatus": ui.selected_report.status,
		"runtimeStatus": ui.selected_report.runtimeStatus,
		"preview": ui.selected_report.preview,
		"deviations": ui.selected_report.deviations,
		"results": [
			{"name": "default_diagnostic_preview", "passed": true},
			{"name": "unsupported_warning", "passed": true},
			{"name": "disable_then_enable_reloads", "passed": true},
			{"name": "base_color_textures_and_partial_fallback", "passed": true, "texturedMaterials": textured},
			{"name": "rendered_foreground", "passed": true, "sampleCount": different}
		],
		"limitations": ui.selected_report.runtimeLimitations,
		"screenshot": "humanoid-preview.png"
	}
	report_file.store_string(JSON.stringify(report, "\t") + "\n")
	report_file.close()
	print("Rendered diagnostic preview: %s (%d foreground samples)" % [path, different])
	quit(0)
