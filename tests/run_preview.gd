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
	var report := {
		"reportType": "ADM diagnostic geometry preview smoke test",
		"specification": {"version": "ADM 1.0", "commit": Validator.SPEC_SHA, "url": Validator.SPEC_URL},
		"engineVersion": Engine.get_version_info().string,
		"results": results,
		"limitations": [
			"Headless test checks decoded geometry and hierarchy, not rasterized pixels.",
			"Diagnostic preview supports base color PNG/JPEG and selected sampler modes only; full PBR, skinning, morphs, animation and IK are unsupported.",
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
		manifest.textures[0].sampler = 0
		manifest.samplers = [{"wrapS": "MIRRORED_REPEAT"}]
		var unsupported := Preview._base_texture({"index": 0}, {"TEXCOORD_0": 0}, 3, manifest, chunks, bytes, {})
		results.append({"name": "unsupported_sampler_reported_%s" % format, "passed": unsupported.has("warning")})
	return results
