extends SceneTree

const Preview = preload("res://scripts/adm_preview.gd")
const Validator = preload("res://scripts/adm_validator.gd")
const REPORT := "res://reports/preview-smoke.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var cases := [
		{"file": "triangle.adm", "diagnostic": false, "expected": "preview"},
		{"file": "shader_layered.adm", "diagnostic": false, "expected": "preview"},
		{"file": "humanoid.adm", "diagnostic": false, "expected": "blocked"},
		{"file": "humanoid.adm", "diagnostic": true, "expected": "preview"}
	]
	var results: Array = []
	var passed := true
	for test_case in cases:
		var path: String = "res://ADM".path_join(test_case.file)
		var result: Dictionary = Preview.load_path(path, test_case.diagnostic)
		var actual := "preview" if result.has("root") else "blocked"
		var success: bool = actual == test_case.expected
		var row := {"source": test_case.file, "diagnostic": test_case.diagnostic, "expected": test_case.expected, "actual": actual, "passed": success}
		if result.has("report"):
			row.assetSha256 = result.report.assetSha256
			row.validationStatus = result.report.status
			if result.report.has("preview"):
				row.preview = result.report.preview
				success = success and result.report.preview.meshPrimitives > 0 and result.report.preview.triangles > 0
				if test_case.file == "triangle.adm":
					success = success and result.report.preview.vertices == 3 and result.report.preview.triangles == 1
					success = success and result.report.preview.boundsMin == [0.0, 0.0, 0.0]
					success = success and result.report.preview.boundsMax == [1.0, 1.0, 0.0]
					success = success and result.report.preview.jointDisplay.status == "unavailable" and not result.root.has_node("ADMJointDisplay")
				if test_case.file == "humanoid.adm":
					success = success and result.report.preview.meshPrimitives == 23 and result.report.preview.triangles == 276
					var textured := 0
					for material_info in result.report.preview.materials:
						if material_info.baseColorTexture == "png_jpeg":
							textured += 1
					success = success and textured == 3
		if result.has("error"):
			row.error = result.error
		if result.has("root"):
			result.root.free()
		row.passed = success
		passed = passed and success
		results.append(row)
	var file := FileAccess.open("res://ADM/triangle.adm", FileAccess.READ)
	if file == null:
		push_error("Cannot open triangle fixture: %s" % error_string(FileAccess.get_open_error()))
		quit(1)
		return
	var bytes := file.get_buffer(file.get_length())
	var invalid_report: Dictionary = Validator.inspect_bytes(bytes, "triangle.adm")
	invalid_report.manifest.nodes[0].children = [0]
	var invalid: Dictionary = Preview.build(bytes, invalid_report, false)
	var rejected: bool = invalid.has("error") and not invalid.has("root")
	results.append({"name": "cyclic_node_is_rejected", "passed": rejected, "error": invalid.get("error", "")})
	passed = passed and rejected
	var index_report: Dictionary = Validator.inspect_bytes(bytes, "triangle.adm")
	var directory_offset := Validator._u64(bytes, 40)
	var chunk_offset := Validator._u64(bytes, directory_offset + 24)
	var damaged := bytes.duplicate()
	damaged[chunk_offset + 36] = 9
	var bad_index: Dictionary = Preview.build(damaged, index_report, false)
	var index_rejected: bool = bad_index.has("error") and not bad_index.has("root")
	results.append({"name": "invalid_vertex_index_is_rejected", "passed": index_rejected, "error": bad_index.get("error", "")})
	passed = passed and index_rejected
	var material_results := _material_tests()
	for test in material_results:
		results.append(test)
		passed = passed and test.passed
	for test in _joint_display_tests(bytes):
		results.append(test)
		passed = passed and test.passed
	for test in _detail_mask_tests():
		results.append(test)
		passed = passed and test.passed
	var human_path := "res://ADM/human.adm"
	if FileAccess.file_exists(human_path) and FileAccess.get_sha256(human_path) == "f96b4571ff5f373aa0cb1085497f061feec1132ef45a597c0109675eb7feae02":
		var human: Dictionary = Preview.load_path(human_path, true)
		var human_passed: bool = human.has("root") and human.report.status == "unsupported"
		if human_passed:
			human_passed = human.report.preview.materials.size() == 1
		if human_passed:
			human_passed = human.report.preview.materials[0].emissiveTexture == "fallback_png_jpeg"
		if human_passed:
			var info: Dictionary = human.report.preview.materials[0]
			human_passed = info.get("shaderRendering") == "partial_diagnostic" and not info.shaderSupported and not info.shaderFallbackActive
			human_passed = human_passed and info.get("color1RTexture") == "fallback_png_jpeg" and info.get("color1RRoughnessTexture") == "fallback_png_jpeg"
		if human_passed:
			var lines: MeshInstance3D = human.root.get_node_or_null("ADMJointDisplay")
			human_passed = human.report.preview.jointDisplay.count == 67 and lines != null and not lines.visible
			if human_passed:
				human_passed = lines.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == 67 * 8
		var row := {"name": "local_human_emissive_fallback", "passed": human_passed}
		if human.has("report"):
			row.assetSha256 = human.report.assetSha256
			row.preview = human.report.get("preview", {})
		if human.has("error"):
			row.error = human.error
		if human.has("root"):
			human.root.free()
		results.append(row)
		passed = passed and human_passed
	elif FileAccess.file_exists(human_path):
		results.append({"name": "local_human_emissive_fallback", "skipped": true, "reason": "The local human.adm differs from the asset used for this regression."})
	var report := {
		"reportType": "ADM diagnostic geometry preview smoke test",
		"specification": {"version": "ADM 1.0", "commit": Validator.SPEC_SHA, "url": Validator.SPEC_URL},
		"engineVersion": Engine.get_version_info().string,
		"results": results,
		"limitations": [
			"Headless test checks decoded geometry and hierarchy, not rasterized pixels.",
			"Diagnostic preview supports base color and emission PNG/JPEG, including KTX2/DDS fallback images, and selected sampler modes only; full PBR, skinning, morphs, animation and IK are unsupported.",
			"GPU texture containers are not decoded or fully validated; fallback source header dimensions are checked.",
			"Emissive material output does not imply bloom, glow or illumination of other geometry.",
			"Joint frames are diagnostic rest-pose geometry only; extension import/export and full validation are not implemented.",
			"COLOR_1.R is a partial diagnostic shader, not a fully supported shader or a PBR fallback; normal and metallic maps and other vertex-control effects remain unsupported.",
			"Uploaded asset provenance is not established."
		]
	}
	var output := FileAccess.open(REPORT, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write preview report: %s" % error_string(FileAccess.get_open_error()))
		quit(1)
		return
	output.store_string(JSON.stringify(report, "\t") + "\n")
	output.close()
	print("Preview report: %s" % ProjectSettings.globalize_path(REPORT))
	quit(0 if passed else 1)


func _detail_mask_tests() -> Array:
	var bytes := PackedByteArray()
	bytes.resize(32)
	for index in range(8):
		bytes.encode_float(index * 4, [0.0, 0.25, 0.5, 1.0, 1.0, 0.0, 0.0, 0.0][index])
	var manifest := {
		"accessors": [{"type": "VEC4", "componentType": "F32", "count": 2, "bufferView": 0}],
		"bufferViews": [{"chunkId": 1, "byteOffset": 0, "byteLength": 32}]
	}
	var chunks := {1: {"offset": 0, "codec": 0}}
	var decoded := Preview._detail_mask({"COLOR_1": 0}, 2, manifest, chunks, bytes)
	var float_ok: bool = decoded.has("colors") and decoded.colors.size() == 2
	if float_ok:
		float_ok = decoded.colors[0].is_equal_approx(Color(0.0, 0.25, 0.5, 1.0)) and decoded.colors[1].r == 1.0
	var no_mask := Preview._detail_mask({}, 2, manifest, chunks, bytes)
	var absent_ok: bool = no_mask.colors.size() == 2 and no_mask.colors[0] == Color(0, 0, 0, 0)
	bytes.encode_float(0, 1.1)
	var invalid := Preview._detail_mask({"COLOR_1": 0}, 2, manifest, chunks, bytes)
	var truncated := Preview._detail_mask({"COLOR_1": 0}, 2, manifest, chunks, bytes.slice(0, 20))
	manifest.bufferViews[0].byteLength = 4
	var short_view := Preview._detail_mask({"COLOR_1": 0}, 2, manifest, chunks, bytes)
	var encoded := PackedByteArray([0, 128, 255, 0])
	manifest.accessors[0] = {"type": "VEC4", "componentType": "U8", "normalized": true, "count": 1, "bufferView": 0}
	var u8 := Preview._detail_mask({"COLOR_1": 0}, 1, manifest, chunks, encoded)
	var u8_ok: bool = u8.has("colors") and is_equal_approx(u8.colors[0].g, 128.0 / 255.0) and u8.colors[0].b == 1.0
	manifest.accessors[0].normalized = false
	var unnormalized := Preview._detail_mask({"COLOR_1": 0}, 1, manifest, chunks, encoded)
	return [
		{"name": "color1_f32_linear_values", "passed": float_ok},
		{"name": "color1_absent_defaults_to_zero", "passed": absent_ok},
		{"name": "color1_out_of_range_rejected", "passed": invalid.has("error")},
		{"name": "color1_truncated_file_rejected", "passed": truncated.has("error")},
		{"name": "color1_truncated_view_rejected", "passed": short_view.has("error")},
		{"name": "color1_u8_normalized", "passed": u8_ok},
		{"name": "color1_u8_unnormalized_rejected", "passed": unnormalized.has("error")}
	]


func _joint_display_tests(bytes: PackedByteArray) -> Array:
	var results: Array = []
	var frame := {
		"version": "1.0.0",
		"displayFrame": [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1],
		"tail": [0, 2, 0]
	}
	var report: Dictionary = Validator.inspect_bytes(bytes, "triangle.adm")
	report.manifest.nodes[0].translation = [10, 0, 0]
	report.manifest.nodes[0].rotation = [0, 0, sqrt(0.5), sqrt(0.5)]
	report.manifest.nodes[0].scale = [2, 3, 1]
	report.manifest.nodes[0].children = [1]
	report.manifest.nodes.append({"translation": [0, 1, 0], "extensions": {"ADM_joint_display_v1": frame}})
	report.manifest.extensionsUsed = ["ADM_joint_display_v1"]
	report.manifest.extensionsRequired = ["ADM_joint_display_v1"]
	report.manifest.skins = [{"joints": [1]}]
	var built: Dictionary = Preview.build(bytes, report, false)
	var geometry_ok := built.has("root")
	if geometry_ok:
		var lines: MeshInstance3D = built.root.get_node_or_null("ADMJointDisplay")
		geometry_ok = lines != null and not lines.visible and built.report.preview.jointDisplay.count == 1
		if geometry_ok:
			var vertices: PackedVector3Array = lines.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			geometry_ok = vertices.size() == 8
			if geometry_ok:
				geometry_ok = vertices[0].is_equal_approx(Vector3(7, 2, 0)) and vertices[1].is_equal_approx(Vector3(7, -2, 0))
				geometry_ok = geometry_ok and vertices[3].is_equal_approx(Vector3(6.4, 2, 0)) and vertices[5].is_equal_approx(Vector3(7, 1.4, 0))
		built.root.free()
	results.append({"name": "joint_display_hierarchy_endpoints_and_roll", "passed": geometry_ok, "error": built.get("error", "")})
	report.manifest.nodes[1].erase("extensions")
	var missing := Preview.build(bytes, report, false)
	results.append({"name": "required_joint_display_missing_is_rejected", "passed": missing.has("error") and not missing.has("root") and missing.report.status == "invalid" and missing.report.diagnostics.has(missing.error)})
	report.manifest.nodes[1].extensions = {"ADM_joint_display_v1": frame}
	report.manifest.erase("extensionsUsed")
	var undeclared := Preview.build(bytes, report, false)
	results.append({"name": "undeclared_joint_display_is_rejected", "passed": undeclared.has("error") and not undeclared.has("root")})
	var invalid_cases := {
		"non_affine": {"displayFrame": [0, 1, 0, 1, -1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1]},
		"singular": {"displayFrame": [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1]},
		"non_finite": {"tail": [0, INF, 0]},
		"zero_tail": {"tail": [0, 0, 0]},
		"extra_member": {"extra": true},
		"wrong_version": {"version": "2.0.0"}
	}
	for name in invalid_cases:
		var damaged: Dictionary = frame.duplicate(true)
		damaged.merge(invalid_cases[name], true)
		var parsed := Preview._joint_display_frame(damaged)
		results.append({"name": "joint_display_invalid_" + name, "passed": parsed.has("error")})
	var large_axis: Vector3 = Preview._display_axis(Vector3(1e30, 0, 0))
	var small_axis: Vector3 = Preview._display_axis(Vector3(1e-30, 0, 0))
	results.append({"name": "joint_display_axes_handle_numeric_scale", "passed": large_axis.is_equal_approx(Vector3.RIGHT) and small_axis.is_equal_approx(Vector3.RIGHT)})
	return results


func _material_tests() -> Array:
	var results: Array = []
	var image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1.0, 0.0, 0.0, 1.0))
	image.set_pixel(1, 0, Color(0.0, 1.0, 0.0, 1.0))
	image.set_pixel(0, 1, Color(0.0, 0.0, 1.0, 1.0))
	image.set_pixel(1, 1, Color(1.0, 1.0, 1.0, 0.5))
	for format in ["image/png", "image/jpeg"]:
		var encoded: PackedByteArray = image.save_png_to_buffer() if format == "image/png" else image.save_jpg_to_buffer(0.95)
		var bytes := PackedByteArray()
		bytes.resize(24)
		bytes.encode_float(0, 0.0)
		bytes.encode_float(4, 0.0)
		bytes.encode_float(8, 1.0)
		bytes.encode_float(12, 0.0)
		bytes.encode_float(16, 0.0)
		bytes.encode_float(20, 1.0)
		bytes.append_array(encoded)
		var manifest := {
			"accessors": [{"bufferView": 0, "componentType": "F32", "type": "VEC2", "count": 3}],
			"bufferViews": [{"chunkId": 1, "byteOffset": 0, "byteLength": 24}, {"chunkId": 2, "byteOffset": 0, "byteLength": encoded.size()}],
			"textures": [{"source": 0}],
			"images": [{"bufferView": 1, "mimeType": format}]
		}
		var chunks := {1: {"codec": 0, "offset": 0, "type": "GEOM"}, 2: {"codec": 0, "offset": 24, "type": "IMAG"}}
		var binding := Preview._base_texture({"index": 0}, {"TEXCOORD_0": 0}, 3, manifest, chunks, bytes, {})
		var success: bool = not binding.has("error") and not binding.has("warning")
		if success:
			var decoded: Image = binding.texture.get_image()
			success = decoded.get_width() == 2 and decoded.get_height() == 2
			success = success and binding.uv == PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
			if format == "image/png":
				success = success and decoded.get_pixel(0, 0).is_equal_approx(Color.RED)
				success = success and abs(decoded.get_pixel(1, 1).a - 0.5) < 0.01
		results.append({"name": "base_texture_%s_uv_and_image" % format, "passed": success, "details": binding.get("error", binding.get("warning", ""))})
		var missing := Preview._base_texture({"index": 0}, {}, 3, manifest, chunks, bytes, {})
		results.append({"name": "missing_uv_rejected_%s" % format, "passed": missing.has("error")})
		if format == "image/png":
			var geometry := bytes.duplicate()
			var geometry_offset := geometry.size()
			geometry.resize(geometry_offset + 42)
			for i in range(9):
				geometry.encode_float(geometry_offset + i * 4, [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0][i])
			for i in range(3):
				geometry.encode_u16(geometry_offset + 36 + i * 2, i)
			manifest.bufferViews.append({"chunkId": 3, "byteOffset": 0, "byteLength": 36})
			manifest.bufferViews.append({"chunkId": 3, "byteOffset": 36, "byteLength": 6})
			manifest.accessors.append({"bufferView": 2, "componentType": "F32", "type": "VEC3", "count": 3})
			manifest.accessors.append({"bufferView": 3, "componentType": "U16", "type": "SCALAR", "count": 3})
			chunks[3] = {"codec": 0, "offset": geometry_offset, "type": "GEOM"}
			manifest.materials = [{"emissiveFactor": [2.0, 1.0, 0.0], "emissiveTexture": {"index": 0}}]
			var primitive := {"attributes": {"POSITION": 1, "TEXCOORD_0": 0}, "indices": 2, "material": 0}
			var built := Preview._primitive(primitive, manifest, chunks, geometry, 3, 3, {})
			var emission_ok: bool = not built.has("error")
			if emission_ok:
				var material: StandardMaterial3D = built.mesh.surface_get_material(0)
				emission_ok = material.emission_enabled and material.emission_texture != null
				emission_ok = emission_ok and material.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY
				emission_ok = emission_ok and is_equal_approx(material.emission_energy_multiplier, 2.0)
				emission_ok = emission_ok and material.emission.is_equal_approx(Color(1.0, 0.5, 0.0).linear_to_srgb())
			results.append({"name": "emissive_factor_multiplies_texture", "passed": emission_ok, "details": built.get("error", "")})
			manifest.materials[0].baseColorTexture = {"index": 0}
			manifest.textures.append({"source": 0, "sampler": 0})
			manifest.samplers = [{"magFilter": "NEAREST", "minFilter": "NEAREST"}]
			manifest.materials[0].emissiveTexture = {"index": 1}
			var conflicting := Preview._primitive(primitive, manifest, chunks, geometry, 3, 3, {})
			var conflict_ok: bool = not conflicting.has("error") and conflicting.material_info.emissiveTexture == "unsupported"
			if conflict_ok:
				var material: StandardMaterial3D = conflicting.mesh.surface_get_material(0)
				conflict_ok = not material.emission_enabled and not material.emission_texture
			results.append({"name": "different_emissive_sampler_is_reported", "passed": conflict_ok, "details": conflicting.get("error", "")})
			var mask_offset := geometry.size()
			geometry.resize(mask_offset + 48)
			for i in range(3):
				geometry.encode_float(mask_offset + i * 16, float(i) * 0.5)
			manifest.bufferViews.append({"chunkId": 4, "byteOffset": 0, "byteLength": 48})
			manifest.accessors.append({"bufferView": 4, "componentType": "F32", "type": "VEC4", "count": 3})
			chunks[4] = {"codec": 0, "offset": mask_offset, "type": "GEOM"}
			manifest.extensionsUsed = ["ADM_vertex_control_v1"]
			manifest.extensionsRequired = ["ADM_vertex_control_v1"]
			manifest.materials[0] = {
				"shader": {"id": "adm.pbr.metallic_roughness", "version": "2.1.0"},
				"shaderParameters": {"color1_r_texture": {"index": 0}, "color1_r_strength": 0.5}
			}
			primitive.attributes.COLOR_1 = 3
			var detail := Preview._primitive(primitive, manifest, chunks, geometry, 3, 3, {}, true)
			var detail_ok: bool = not detail.has("error") and detail.material_info.get("shaderRendering") == "partial_diagnostic"
			if detail_ok:
				var preview_material: ShaderMaterial = detail.mesh.surface_get_material(0)
				var colors: PackedColorArray = detail.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
				detail_ok = is_equal_approx(preview_material.get_shader_parameter("detail_strength"), 0.5) and colors.size() == 3 and abs(colors[1].r - 0.5) < 0.01
			results.append({"name": "detail_shader_binds_authored_mask_and_strength", "passed": detail_ok})
			manifest.materials[0].shader.version = "2.0.0"
			var other_version := Preview._primitive(primitive, manifest, chunks, geometry, 3, 3, {}, true)
			results.append({"name": "detail_shader_does_not_substitute_other_versions", "passed": not other_version.has("error") and not other_version.material_info.has("shaderRendering") and other_version.material_info.shaderFallbackActive})
			manifest.materials[0].shader.version = "2.1.0"
			var no_diagnostic := Preview._primitive(primitive, manifest, chunks, geometry, 3, 3, {}, false)
			results.append({"name": "detail_shader_requires_diagnostic_override", "passed": not no_diagnostic.has("error") and not no_diagnostic.material_info.has("shaderRendering") and no_diagnostic.material_info.shaderFallbackActive})
			manifest.extensionsRequired = []
			var undeclared := Preview._primitive(primitive, manifest, chunks, geometry, 3, 3, {}, true)
			results.append({"name": "detail_shader_requires_vertex_control_extension", "passed": undeclared.has("error")})
			manifest.bufferViews.resize(2)
			manifest.accessors.resize(1)
			manifest.textures.resize(1)
			chunks.erase(3)
			chunks.erase(4)
		manifest.textures[0].sampler = 0
		manifest.samplers = [{"wrapS": "MIRRORED_REPEAT"}]
		var unsupported := Preview._base_texture({"index": 0}, {"TEXCOORD_0": 0}, 3, manifest, chunks, bytes, {})
		results.append({"name": "unsupported_sampler_reported_%s" % format, "passed": unsupported.has("warning")})
		manifest.textures[0].erase("sampler")
		for gpu_type in ["image/vnd-ms.dds", "image/ktx2"]:
			var header := PackedByteArray()
			header.resize(148 if gpu_type == "image/vnd-ms.dds" else 80)
			header.fill(0)
			if gpu_type == "image/vnd-ms.dds":
				for i in range(4):
					header[i] = "DDS ".to_ascii_buffer()[i]
					header[84 + i] = "DX10".to_ascii_buffer()[i]
				header.encode_u32(4, 124)
				header.encode_u32(12, 2)
				header.encode_u32(16, 2)
			else:
				var signature := PackedByteArray([171, 75, 84, 88, 32, 50, 48, 187, 13, 10, 26, 10])
				for i in range(signature.size()):
					header[i] = signature[i]
				header.encode_u32(20, 2)
				header.encode_u32(24, 2)
			var gpu_bytes := bytes.duplicate()
			gpu_bytes.append_array(header)
			var gpu_manifest: Dictionary = manifest.duplicate(true)
			gpu_manifest.bufferViews.append({"chunkId": 3, "byteOffset": 0, "byteLength": header.size()})
			gpu_manifest.images.append({"bufferView": 2, "mimeType": gpu_type})
			gpu_manifest.textures[0] = {"source": 1, "fallbackSource": 0}
			var gpu_chunks: Dictionary = chunks.duplicate(true)
			gpu_chunks[3] = {"codec": 0, "offset": bytes.size(), "type": "IMAG"}
			var fallback := Preview._base_texture({"index": 0}, {"TEXCOORD_0": 0}, 3, gpu_manifest, gpu_chunks, gpu_bytes, {})
			results.append({"name": "gpu_texture_fallback_%s_%s" % [gpu_type, format], "passed": not fallback.has("error") and not fallback.has("warning") and fallback.get("source") == "fallback_png_jpeg"})
			gpu_manifest.textures[0].erase("fallbackSource")
			var missing_fallback := Preview._base_texture({"index": 0}, {"TEXCOORD_0": 0}, 3, gpu_manifest, gpu_chunks, gpu_bytes, {})
			results.append({"name": "gpu_texture_missing_fallback_%s_%s" % [gpu_type, format], "passed": missing_fallback.has("error")})
			gpu_manifest.textures[0].fallbackSource = 0
			gpu_bytes.encode_u32(bytes.size() + (16 if gpu_type == "image/vnd-ms.dds" else 20), 3)
			var mismatch := Preview._base_texture({"index": 0}, {"TEXCOORD_0": 0}, 3, gpu_manifest, gpu_chunks, gpu_bytes, {})
			results.append({"name": "gpu_texture_mismatched_fallback_%s_%s" % [gpu_type, format], "passed": mismatch.has("error")})
	return results
