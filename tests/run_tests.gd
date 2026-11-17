extends SceneTree

const Validator = preload("res://scripts/adm_validator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid_bytes := _make_animation_fixture([])
	var unknown_optional_bytes := _make_animation_fixture(["ADM_future_optional"])
	var unknown_required_bytes := _make_animation_fixture(["ADM_future_required"], false, false, ["ADM_future_required"])
	var duplicate_key_bytes := _make_animation_fixture([], false, false, [], true)
	var nested_optional_bytes := _make_animation_fixture(["ADM_future_optional"], false, false, [], false, true)
	var declaration_only_bytes := _make_animation_fixture(["ADM_future_optional"], false, false, [], false, false, true)
	var chunked_bytes := _make_animation_fixture([], true)
	var unpadded_bytes := chunked_bytes.duplicate()
	unpadded_bytes.resize(unpadded_bytes.size() - 12)
	_write_u64(unpadded_bytes, 16, unpadded_bytes.size())
	var unknown_chunk_bytes := chunked_bytes.duplicate()
	var unknown_dir := unknown_chunk_bytes.decode_u64(40)
	_copy(unknown_chunk_bytes, unknown_dir + 8, "FUTR".to_ascii_buffer())
	var invalid_hash_bytes := _make_animation_fixture([], true, true)
	var invalid_bytes := valid_bytes.duplicate()
	invalid_bytes[4] = 2
	var cases := [
		{"name": "valid_metadata_only_animation", "bytes": valid_bytes, "expected": "supported"},
		{"name": "valid_raw_data_chunk_and_hash", "bytes": chunked_bytes, "expected": "supported"},
		{"name": "valid_unpadded_raw_chunk", "bytes": unpadded_bytes, "expected": "supported"},
		{"name": "unknown_required_chunk", "bytes": unknown_chunk_bytes, "expected": "unsupported"},
		{"name": "raw_chunk_hash_mismatch", "bytes": invalid_hash_bytes, "expected": "invalid"},
		{"name": "unknown_optional_extension", "bytes": unknown_optional_bytes, "expected": "supported"},
		{"name": "nested_optional_extension", "bytes": nested_optional_bytes, "source": "fixture.adm", "expected": "supported"},
		{"name": "declaration_without_root_extension_data", "bytes": declaration_only_bytes, "expected": "supported"},
		{"name": "unknown_required_extension", "bytes": unknown_required_bytes, "expected": "unsupported"},
		{"name": "duplicate_json_member", "bytes": duplicate_key_bytes, "expected": "invalid"},
		{"name": "unsupported_major_version", "bytes": invalid_bytes, "expected": "unsupported"}
	]
	var chain := [
		{"chunkId": 1, "requires": [2]},
		{"chunkId": 2, "requires": [3]}
	]
	cases.append_array([
		{"name": "valid_transitive_dependencies", "bytes": _make_dependency_fixture(chain), "expected": "supported"},
		{"name": "transitive_unavailable_codec", "bytes": _make_dependency_fixture(chain, 1), "expected": "unsupported", "message": "chunk 3"},
		{"name": "unavailable_dependency_prevents_accessor_interpretation", "bytes": _make_dependency_fixture(chain, 1, "DATA", [], false, true), "expected": "unsupported", "message": "chunk 3"},
		{"name": "available_dependency_checks_accessor", "bytes": _make_dependency_fixture(chain, 0, "DATA", [], false, true), "expected": "invalid", "message": "non-finite"},
		{"name": "required_chunk_unavailable_dependency", "bytes": _make_dependency_fixture(chain, 1, "DATA", [], true), "expected": "unsupported", "message": "chunk 3"},
		{"name": "transitive_unknown_chunk", "bytes": _make_dependency_fixture(chain, 0, "FUTR"), "expected": "unsupported", "message": "needed chunk 3"},
		{"name": "unneeded_optional_codec", "bytes": _make_dependency_fixture([], 1), "expected": "supported", "message": "unreferenced ZSTD chunk 3"},
		{"name": "unknown_dependency_owner", "bytes": _make_dependency_fixture([{"chunkId": 4, "requires": []}]), "expected": "invalid", "message": "unknown chunkId"},
		{"name": "unknown_dependency", "bytes": _make_dependency_fixture([{"chunkId": 1, "requires": [4]}]), "expected": "invalid", "message": "dependency"},
		{"name": "duplicate_dependency", "bytes": _make_dependency_fixture([{"chunkId": 1, "requires": [2, 2]}]), "expected": "invalid", "message": "dependency"},
		{"name": "self_dependency", "bytes": _make_dependency_fixture([{"chunkId": 1, "requires": [1]}]), "expected": "invalid", "message": "dependency"},
		{"name": "dependency_extra_field", "bytes": _make_dependency_fixture([{"chunkId": 1, "requires": [], "extra": 0}]), "expected": "invalid", "message": "chunkDependencies"},
		{"name": "duplicate_dependency_entry", "bytes": _make_dependency_fixture([{"chunkId": 1, "requires": []}, {"chunkId": 1, "requires": []}]), "expected": "invalid", "message": "duplicate chunkId"},
		{"name": "dependency_cycle", "bytes": _make_dependency_fixture([{"chunkId": 1, "requires": [2]}, {"chunkId": 2, "requires": [3]}, {"chunkId": 3, "requires": [1]}]), "expected": "invalid", "message": "cycle"},
		{"name": "disconnected_dependency_cycle", "bytes": _make_dependency_fixture([{"chunkId": 2, "requires": [3]}, {"chunkId": 3, "requires": [2]}]), "expected": "invalid", "message": "cycle"},
		{"name": "valid_stream_hints", "bytes": _make_dependency_fixture([], 0, "DATA", [{"chunkId": 1, "priority": 0}, {"chunkId": 3, "priority": 255}]), "expected": "supported"},
		{"name": "duplicate_stream_hint", "bytes": _make_dependency_fixture([], 0, "DATA", [{"chunkId": 1, "priority": 0}, {"chunkId": 1, "priority": 1}]), "expected": "invalid", "message": "streamHints"},
		{"name": "invalid_stream_priority", "bytes": _make_dependency_fixture([], 0, "DATA", [{"chunkId": 2, "priority": 256}]), "expected": "invalid", "message": "priority"},
	])
	var test_results: Array = []
	var passed := true
	for test_case in cases:
		var result: Dictionary = Validator.inspect_bytes(test_case.bytes, test_case.get("source", "fixture.adm_anim"))
		var success: bool = result.status == test_case.expected
		if test_case.has("message"):
			var messages: String = " ".join(result.diagnostics + result.unsupported)
			success = success and messages.contains(test_case.message)
		passed = passed and success
		test_results.append({
			"name": test_case.name,
			"expected": test_case.expected,
			"actual": result.status,
			"passed": success,
			"assetSha256": result.assetSha256,
			"diagnostics": result.diagnostics,
			"unsupported": result.unsupported
		})
	var report := {
		"reportType": "ADM validation milestone smoke test",
		"specification": {"version": "ADM 1.0", "commit": Validator.SPEC_SHA, "url": Validator.SPEC_URL},
		"engineVersion": "Godot 4.7.2-stable",
		"capabilities": Validator.IMPLEMENTED_CAPABILITIES,
		"results": test_results,
		"deviations": [
			"Validation covers a documented subset of ADM 1.0; it is not a conformance claim.",
			"Smoke tests use synthetic fixtures; the separate uploaded-assets report covers the user-supplied files."
		],
		"limitations": [
			"Cross-engine reference provenance and independently verified conformance are not established.",
			"Only a separate diagnostic static geometry preview with partial material and PNG/JPEG texture support exists; animation evaluation and IK solving are not implemented.",
			"The reader loads entire files; ADM-STREAM-1 and partial-loading APIs are not implemented.",
			"Full per-feature schema validation and JSON integer lexical-form checks are not yet implemented."
		]
	}
	var report_path := ProjectSettings.globalize_path("res://reports/validation-smoke.json")
	var output_file := FileAccess.open(report_path, FileAccess.WRITE)
	if output_file == null:
		push_error("Cannot write smoke report: %s" % error_string(FileAccess.get_open_error()))
		quit(1)
		return
	output_file.store_string(JSON.stringify(report, "\t") + "\n")
	output_file.close()
	print("ADM smoke report: %s" % report_path)
	quit(0 if passed else 1)


func _make_animation_fixture(extensions_used: Array, include_chunk: bool = false, corrupt_sha: bool = false, extensions_required: Array = [], duplicate_key: bool = false, nested_extension: bool = false, declaration_only: bool = false) -> PackedByteArray:
	var manifest: Dictionary = {
		"asset": {"generator": "ADM validation smoke test"},
		"library": {
			"id": "test@validation",
			"title": "Validation fixture",
			"description": "Synthetic metadata-only ADM animation fixture.",
			"language": "en",
			"targetProfile": "model.any.v1",
			"binding": "SEMANTIC"
		},
		"clips": [],
		"bufferViews": [],
		"accessors": []
	}
	if include_chunk:
		manifest.bufferViews = [{"chunkId": 1, "byteOffset": 0, "byteLength": 4}]
		manifest.accessors = [{"bufferView": 0, "componentType": "U8", "type": "SCALAR", "count": 4}]
	if not extensions_used.is_empty():
		if nested_extension:
			manifest = {
				"asset": {"generator": "ADM validation smoke test"},
				"nodes": [],
				"scenes": [{"nodes": []}],
				"scene": 0,
				"meshes": [],
				"bufferViews": [],
				"accessors": [],
				"materials": [{"extensions": {}}]
			}
		manifest.extensionsUsed = extensions_used
		if nested_extension:
			for extension_name in extensions_used:
				manifest.materials[0].extensions[extension_name] = {}
		elif not declaration_only:
			manifest.extensions = {}
			for extension_name in extensions_used:
				manifest.extensions[extension_name] = {}
	if not extensions_required.is_empty():
		manifest.extensionsRequired = extensions_required
	var manifest_text := JSON.stringify(manifest)
	if duplicate_key:
		manifest_text = manifest_text.replace('"clips":[]', '"clips":[],"clips":[]')
	var manifest_bytes := manifest_text.to_utf8_buffer()
	var manifest_end := 64 + manifest_bytes.size()
	var directory_offset := (manifest_end + 15) & ~15
	var directory_end := directory_offset + (80 if include_chunk else 0)
	var payload_offset := (directory_end + 15) & ~15
	var payload := "DATA".to_ascii_buffer()
	var file_size := (payload_offset + payload.size() + 15) & ~15 if include_chunk else payload_offset
	var bytes := PackedByteArray()
	bytes.resize(file_size)
	bytes.fill(0)
	_copy(bytes, 0, ("ADM0" if nested_extension else "AMA0").to_ascii_buffer())
	_write_u16(bytes, 4, 1)
	_write_u16(bytes, 6, 0)
	_write_u32(bytes, 8, 64)
	_write_u32(bytes, 12, 0)
	_write_u64(bytes, 16, file_size)
	_write_u64(bytes, 24, 64)
	_write_u64(bytes, 32, manifest_bytes.size())
	_write_u64(bytes, 40, directory_offset)
	_write_u32(bytes, 48, 1 if include_chunk else 0)
	_write_u32(bytes, 52, 80)
	_write_u64(bytes, 56, 0)
	_copy(bytes, 64, manifest_bytes)
	if include_chunk:
		_write_u64(bytes, directory_offset, 1)
		_copy(bytes, directory_offset + 8, "DATA".to_ascii_buffer())
		_write_u32(bytes, directory_offset + 12, 1)
		_write_u32(bytes, directory_offset + 16, 0)
		_write_u32(bytes, directory_offset + 20, 0)
		_write_u64(bytes, directory_offset + 24, payload_offset)
		_write_u64(bytes, directory_offset + 32, payload.size())
		_write_u64(bytes, directory_offset + 40, payload.size())
		var payload_hash := _sha256(payload).to_ascii_buffer()
		if corrupt_sha:
			payload_hash[0] = 48 if payload_hash[0] != 48 else 49
		_copy(bytes, directory_offset + 48, _hex_to_bytes(payload_hash.get_string_from_ascii()))
		_copy(bytes, payload_offset, payload)
	return bytes


func _make_dependency_fixture(dependencies: Array, last_codec: int = 0, last_type: String = "DATA", hints: Array = [], first_required: bool = false, nonfinite_first: bool = false) -> PackedByteArray:
	var manifest := {
		"asset": {"generator": "ADM dependency smoke test"},
		"library": {
			"id": "test@dependencies", "title": "Dependencies",
			"description": "Synthetic chunk dependency fixture.", "language": "en",
			"targetProfile": "model.any.v1", "binding": "SEMANTIC"
		},
		"clips": [], "bufferViews": [] if first_required else [{"chunkId": 1, "byteOffset": 0, "byteLength": 4}],
		"accessors": [{"bufferView": 0, "componentType": "F32", "type": "SCALAR", "count": 1}] if nonfinite_first else [],
		"chunkDependencies": dependencies, "streamHints": hints
	}
	var manifest_bytes := JSON.stringify(manifest).to_utf8_buffer()
	var directory_offset := (64 + manifest_bytes.size() + 15) & ~15
	var payload_offset := directory_offset + 3 * 80
	var bytes := PackedByteArray()
	bytes.resize(payload_offset + 3 * 16)
	bytes.fill(0)
	_copy(bytes, 0, "AMA0".to_ascii_buffer())
	_write_u16(bytes, 4, 1)
	_write_u32(bytes, 8, 64)
	_write_u64(bytes, 16, bytes.size())
	_write_u64(bytes, 24, 64)
	_write_u64(bytes, 32, manifest_bytes.size())
	_write_u64(bytes, 40, directory_offset)
	_write_u32(bytes, 48, 3)
	_write_u32(bytes, 52, 80)
	_copy(bytes, 64, manifest_bytes)
	for index in range(3):
		var entry := directory_offset + index * 80
		var payload := ("D%03d" % index).to_ascii_buffer()
		if index == 0 and nonfinite_first:
			payload.encode_u32(0, 0x7f800000)
		_write_u64(bytes, entry, index + 1)
		_copy(bytes, entry + 8, (last_type if index == 2 else "DATA").to_ascii_buffer())
		_write_u32(bytes, entry + 12, 1 if first_required and index == 0 else 0)
		_write_u32(bytes, entry + 16, last_codec if index == 2 else 0)
		_write_u64(bytes, entry + 24, payload_offset + index * 16)
		_write_u64(bytes, entry + 32, payload.size())
		_write_u64(bytes, entry + 40, payload.size())
		_copy(bytes, entry + 48, _hex_to_bytes(_sha256(payload)))
		_copy(bytes, payload_offset + index * 16, payload)
	return bytes


func _copy(target: PackedByteArray, offset: int, source: PackedByteArray) -> void:
	for index in range(source.size()):
		target[offset + index] = source[index]


func _write_u16(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = value & 255
	bytes[offset + 1] = (value >> 8) & 255


func _write_u32(bytes: PackedByteArray, offset: int, value: int) -> void:
	for index in range(4):
		bytes[offset + index] = (value >> (index * 8)) & 255


func _write_u64(bytes: PackedByteArray, offset: int, value: int) -> void:
	for index in range(8):
		bytes[offset + index] = (value >> (index * 8)) & 255


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	var result := ""
	for byte in context.finish():
		result += "%02x" % byte
	return result


func _hex_to_bytes(value: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	for index in range(0, value.length(), 2):
		bytes.append(value.substr(index, 2).hex_to_int())
	return bytes
