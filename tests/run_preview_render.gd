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
	var limitations: Array = ui.selected_report.runtimeLimitations.duplicate()
	limitations.append("Asset provenance and cross-engine comparison are not established.")
	limitations.append("Emission is material output, not bloom or illumination of surrounding geometry.")
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
		"limitations": limitations,
		"screenshot": "humanoid-preview.png"
	}
	report_file.store_string(JSON.stringify(report, "\t") + "\n")
	report_file.close()
	print("Rendered diagnostic preview: %s (%d foreground samples)" % [path, different])
	if FileAccess.file_exists("res://ADM/human.adm") and FileAccess.get_sha256("res://ADM/human.adm") == "f96b4571ff5f373aa0cb1085497f061feec1132ef45a597c0109675eb7feae02":
		if not await _test_human(ui):
			quit(1)
			return
	quit(0)


func _test_human(ui: Control) -> bool:
	ui._inspect_file(ProjectSettings.globalize_path("res://ADM/human.adm"))
	if ui.selected_report.status != "unsupported" or not ui.selected_report.has("preview"):
		push_error("Human diagnostic preview did not load.")
		return false
	var materials: Array = ui.selected_report.preview.materials
	if materials.size() != 1 or materials[0].emissiveTexture != "fallback_png_jpeg" or materials[0].shaderSupported or materials[0].get("shaderRendering") != "partial_diagnostic" or materials[0].get("color1RTexture") != "fallback_png_jpeg":
		push_error("Human emissive fallback or unsupported shader status was not recorded.")
		return false
	await process_frame
	var lines: MeshInstance3D = ui.model_root.get_child(0).get_node_or_null("ADMJointDisplay")
	if lines == null or lines.visible or ui.joint_display_toggle.button_pressed or ui.selected_report.preview.jointDisplay.count != 67:
		push_error("Human joint display must contain 67 frames and be hidden by default.")
		return false
	var detail_material: ShaderMaterial
	for instance in ui.model_root.get_child(0).find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = instance
		if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0 and mesh_instance.mesh.surface_get_material(0) is ShaderMaterial:
			detail_material = mesh_instance.mesh.surface_get_material(0)
	if detail_material == null:
		push_error("Human diagnostic detail shader is missing.")
		return false
	for index in range(10):
		await process_frame
	await RenderingServer.frame_post_draw
	var without_joints: Image = ui.viewport.get_texture().get_image()
	var textured_image_error := without_joints.save_png("res://reports/human-textured-preview.png")
	if textured_image_error != OK:
		push_error("Cannot save textured human preview: %s" % error_string(textured_image_error))
		return false
	detail_material.set_shader_parameter("detail_strength", 0.0)
	for index in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	var without_detail: Image = ui.viewport.get_texture().get_image()
	detail_material.set_shader_parameter("detail_strength", 1.0)
	var detail_changed := _changed_pixels(without_joints, without_detail)
	if detail_changed < 100:
		push_error("Authored COLOR_1.R detail did not visibly affect the model: %d pixels." % detail_changed)
		return false
	ui.joint_display_toggle.button_pressed = true
	for index in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = ui.viewport.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Renderer did not produce the human preview.")
		return false
	if not lines.visible or not ui.selected_report.preview.jointDisplay.visible:
		push_error("Enabling joint display did not update geometry and report.")
		return false
	var changed := _changed_pixels(image, without_joints)
	if changed < 25:
		push_error("Joint display did not visibly change the rendered image: %d pixels." % changed)
		return false
	ui.joint_display_toggle.button_pressed = false
	if lines.visible or ui.selected_report.preview.jointDisplay.visible:
		push_error("Disabling joint display did not update geometry and report.")
		return false
	ui.joint_display_toggle.button_pressed = true
	var corner := image.get_pixel(0, 0)
	var different := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var pixel := image.get_pixel(x, y)
			if abs(pixel.r - corner.r) + abs(pixel.g - corner.g) + abs(pixel.b - corner.b) > 0.1:
				different += 1
	if different < 50:
		push_error("Human preview has too few foreground samples: %d." % different)
		return false
	var image_error := image.save_png("res://reports/human-preview.png")
	if image_error != OK:
		push_error("Cannot save human preview: %s" % error_string(image_error))
		return false
	var output := FileAccess.open("res://reports/human-preview.json", FileAccess.WRITE)
	if output == null:
		push_error("Cannot write human preview report: %s" % error_string(FileAccess.get_open_error()))
		return false
	var limitations: Array = ui.selected_report.runtimeLimitations.duplicate()
	limitations.append("Asset provenance and cross-engine comparison are not established.")
	limitations.append("Emission is material output, not bloom or illumination of surrounding geometry.")
	var report := {
		"reportType": "Human diagnostic preview UI test",
		"assetSha256": ui.selected_report.assetSha256,
		"specification": ui.selected_report.specification,
		"engineVersion": Engine.get_version_info().string,
		"capabilities": ui.selected_report.capabilities,
		"validationStatus": ui.selected_report.status,
		"runtimeStatus": ui.selected_report.runtimeStatus,
		"preview": ui.selected_report.preview,
		"deviations": ui.selected_report.deviations,
		"results": [
			{"name": "rendered_foreground", "passed": true, "sampleCount": different},
			{"name": "authored_color1_r_texture_visible", "passed": true, "changedPixels": detail_changed},
			{"name": "joint_display_toggle_and_pixels", "passed": true, "jointCount": 67, "changedPixels": changed}
		],
		"limitations": limitations,
		"screenshot": "human-preview.png",
		"texturedScreenshot": "human-textured-preview.png"
	}
	output.store_string(JSON.stringify(report, "\t") + "\n")
	output.close()
	return true


func _changed_pixels(a: Image, b: Image) -> int:
	var changed := 0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			var first := a.get_pixel(x, y)
			var second := b.get_pixel(x, y)
			if abs(first.r - second.r) + abs(first.g - second.g) + abs(first.b - second.b) > 0.1:
				changed += 1
	return changed
