extends RefCounted
class_name ADMValidator

const SPEC_SHA := "0fe5ac81683584683a6d83b40bf779d6d219cde5"
const SPEC_URL := "https://github.com/BerretW/ADM/blob/0fe5ac81683584683a6d83b40bf779d6d219cde5/adm-standard/ADM-1.0-SPEC.md"
const HEADER_SIZE := 64
const DIRECTORY_ENTRY_SIZE := 80
const MAX_FILE_SIZE := 1073741824
const MAX_MANIFEST_SIZE := 16777216
const MAX_RAW_CHUNK_SIZE := 268435456
const COMPONENT_SIZES := {"F32": 4, "U32": 4, "U16": 2, "U8": 1}
const COMPONENT_COUNTS := {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
const MODEL_REQUIRED := ["asset", "nodes", "scenes", "scene", "meshes", "accessors", "bufferViews"]
const ANIM_REQUIRED := ["asset", "library", "clips", "bufferViews", "accessors"]
const MODEL_OPTIONAL := [
	"materials", "samplers", "images", "textures", "shaderDefinitions", "skins", "colliders",
	"lodGroups", "attachments", "skeletonProfiles", "facialProfiles", "expressions", "ikChains",
	"componentRoles", "chunkDependencies", "streamHints", "physicalMaterials", "hitboxes",
	"modelComponents", "modelProfiles", "extensionsUsed", "extensionsRequired", "extensions", "extras"
]
const ANIM_OPTIONAL := [
	"eventsSchema", "chunkDependencies", "streamHints", "extensionsUsed", "extensionsRequired",
	"extensions", "extras"
]
const KNOWN_CHUNK_TYPES := ["GEOM", "ANIM", "IMAG", "DATA"]
const IMPLEMENTED_CAPABILITIES := [
	"ADM-CONTAINER-1 (partial: RAW chunks, header/directory/hash and dependency checks; no streaming)",
	"ADM-CORE-1 (metadata and structural validation subset)",
	"ADM-ANIM-1 (container and library metadata validation subset)"
]

static func inspect_path(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _invalid(path.get_file(), "Cannot open file: %s" % error_string(FileAccess.get_open_error()))
	var length := file.get_length()
	if length < 0 or length > MAX_FILE_SIZE:
		return _invalid(path.get_file(), "File exceeds the configured 1 GiB reader limit.")
	return inspect_bytes(file.get_buffer(length), path.get_file())


static func inspect_bytes(bytes: PackedByteArray, source_name: String) -> Dictionary:
	var result := _base_result(source_name, bytes)
	if bytes.size() < HEADER_SIZE:
		return _finish_invalid(result, "File is shorter than the 64-byte ADM header.")
	if bytes.size() > MAX_FILE_SIZE:
		return _finish_invalid(result, "File exceeds the configured 1 GiB reader limit.")

	var magic := _ascii(bytes, 0, 4)
	var expected_magic := ""
	if source_name.to_lower().ends_with(".adm_anim"):
		expected_magic = "AMA0"
	elif source_name.to_lower().ends_with(".adm"):
		expected_magic = "ADM0"
	else:
		return _finish_invalid(result, "Expected a .adm or .adm_anim filename.")
	if magic != expected_magic:
		return _finish_invalid(result, "Magic %s does not match expected %s." % [magic, expected_magic])

	var major := _u16(bytes, 4)
	var minor := _u16(bytes, 6)
	var header_size := _u32(bytes, 8)
	var flags := _u32(bytes, 12)
	var declared_file_size := _u64(bytes, 16)
	var manifest_offset := _u64(bytes, 24)
	var manifest_length := _u64(bytes, 32)
	var directory_offset := _u64(bytes, 40)
	var chunk_count := _u32(bytes, 48)
	var entry_size := _u32(bytes, 52)
	var reserved := _u64(bytes, 56)

	if major != 1 or minor != 0:
		var version_error := "ADM version %d.%d is not supported; expected 1.0." % [major, minor]
		_add_unsupported(result, version_error)
		result.status = "unsupported"
		result.deviations = result.unsupported.duplicate()
		return result
	if header_size != HEADER_SIZE or flags != 0 or reserved != 0:
		return _finish_invalid(result, "Header size, flags, or reserved field is invalid.")
	if declared_file_size != bytes.size():
		return _finish_invalid(result, "Header fileSize does not match the physical file length.")
	if manifest_offset != HEADER_SIZE or manifest_length < 2 or manifest_length > MAX_MANIFEST_SIZE:
		return _finish_invalid(result, "Manifest offset/length is outside the ADM 1.0 limits.")
	if chunk_count > 65535 or entry_size != DIRECTORY_ENTRY_SIZE:
		return _finish_invalid(result, "Chunk count or directory entry size is invalid.")
	if manifest_offset + manifest_length > bytes.size():
		return _finish_invalid(result, "Manifest extends beyond the file.")
	var canonical_directory_offset := _align16(manifest_offset + manifest_length)
	if directory_offset != canonical_directory_offset:
		return _finish_invalid(result, "Directory offset is not the canonical 16-byte aligned offset.")
	if not _zero_range(bytes, manifest_offset + manifest_length, directory_offset):
		return _finish_invalid(result, "Non-zero padding exists between the manifest and directory.")
	var directory_end := directory_offset + chunk_count * DIRECTORY_ENTRY_SIZE
	if directory_end > bytes.size():
		return _finish_invalid(result, "Chunk directory extends beyond the file.")
	var payload_start := _align16(directory_end)
	if payload_start > bytes.size() or not _zero_range(bytes, directory_end, payload_start):
		return _finish_invalid(result, "Directory padding is invalid.")

	var parsed_chunks := _read_directory(bytes, int(directory_offset), int(chunk_count), int(payload_start))
	if parsed_chunks.has("unsupported"):
		_add_unsupported(result, parsed_chunks.unsupported)
		result.status = "unsupported"
		result.deviations = result.unsupported.duplicate()
		return result
	if parsed_chunks.has("error"):
		return _finish_invalid(result, parsed_chunks.error)
	var chunks: Array = parsed_chunks.chunks
	result.chunks = parsed_chunks.public_chunks

	var manifest_bytes := bytes.slice(int(manifest_offset), int(manifest_offset + manifest_length))
	var manifest_text := manifest_bytes.get_string_from_utf8()
	if manifest_text.to_utf8_buffer() != manifest_bytes:
		return _finish_invalid(result, "Manifest is not valid UTF-8.")
	var duplicate_key := _find_duplicate_json_key(manifest_text)
	if duplicate_key.found:
		return _finish_invalid(result, "Manifest contains duplicate JSON object key '%s'." % duplicate_key.key)
	var parsed_json := JSON.new()
	if parsed_json.parse(manifest_text) != OK:
		return _finish_invalid(result, "Manifest JSON parse error at line %d: %s" % [
			parsed_json.get_error_line(), parsed_json.get_error_message()
		])
	if typeof(parsed_json.data) != TYPE_DICTIONARY:
		return _finish_invalid(result, "Manifest root must be a JSON object.")
	var manifest: Dictionary = parsed_json.data
	result.manifest = manifest

	var semantic_error := _validate_manifest(manifest, magic, bytes, chunks, result)
	if not semantic_error.is_empty():
		if semantic_error.begins_with("UNSUPPORTED:"):
			_add_unsupported(result, semantic_error.trim_prefix("UNSUPPORTED:"))
			result.status = "unsupported"
			result.capabilities.declared = result.declared_capabilities
			result.deviations = result.unsupported.duplicate()
			return result
		return _finish_invalid(result, semantic_error)
	result.runtimeStatus = "unsupported"
	result.runtimeLimitations = ["This milestone validates ADM data but does not instantiate or render it."]

	for chunk in chunks:
		if chunk.codec == 0:
			var payload := bytes.slice(chunk.file_offset, chunk.file_offset + chunk.stored_length)
			var actual_hash := _sha256(payload)
			if actual_hash != chunk.sha256:
				return _finish_invalid(result, "SHA-256 mismatch for chunk %d." % chunk.id)
		elif chunk.codec == 1:
			if chunk.required or chunk.referenced:
				_add_unsupported(result, "ADM-CODEC-ZSTD-1 is required by chunk %d but no ZSTD decoder is available." % chunk.id)
			else:
				_add_diagnostic(result, "Optional unreferenced ZSTD chunk %d was not decoded or hash-verified." % chunk.id)
		elif chunk.required or chunk.referenced:
			_add_unsupported(result, "Unsupported codec %d is required by chunk %d." % [chunk.codec, chunk.id])
		else:
			_add_diagnostic(result, "Optional unreferenced chunk %d uses unsupported codec %d." % [chunk.id, chunk.codec])

	result.status = "unsupported" if not result.unsupported.is_empty() else "supported"
	result.capabilities.declared = result.declared_capabilities
	result.deviations = result.unsupported.duplicate()
	return result


static func _read_directory(bytes: PackedByteArray, offset: int, count: int, payload_start: int) -> Dictionary:
	var chunks: Array = []
	var public_chunks: Array = []
	var ids := {}
	var previous_id := 0
	var previous_file_offset := payload_start
	for index in range(count):
		var entry_offset := offset + index * DIRECTORY_ENTRY_SIZE
		var chunk_id := _u64(bytes, entry_offset)
		var chunk_type := _ascii(bytes, entry_offset + 8, 4)
		var entry_flags := _u32(bytes, entry_offset + 12)
		var codec := _u32(bytes, entry_offset + 16)
		var entry_reserved := _u32(bytes, entry_offset + 20)
		var file_offset := _u64(bytes, entry_offset + 24)
		var stored_length := _u64(bytes, entry_offset + 32)
		var raw_length := _u64(bytes, entry_offset + 40)
		var expected_hash := _hex(bytes.slice(entry_offset + 48, entry_offset + 80))
		if chunk_id == 0 or chunk_id > 4294967295 or chunk_id <= previous_id or ids.has(chunk_id):
			return {"error": "Chunk IDs must be unique, nonzero, u32-compatible and strictly increasing."}
		if entry_flags & ~1 != 0 or entry_reserved != 0:
			return {"error": "Chunk %d has invalid flags or reserved bits." % chunk_id}
		var type_is_ascii := true
		for byte_index in range(4):
			var code := bytes[entry_offset + 8 + byte_index]
			type_is_ascii = type_is_ascii and code >= 32 and code <= 126
		if chunk_type.length() != 4 or not type_is_ascii:
			return {"error": "Chunk %d has an invalid FourCC." % chunk_id}
		if stored_length <= 0 or raw_length <= 0 or raw_length > MAX_RAW_CHUNK_SIZE:
			return {"error": "Chunk %d has an invalid length or exceeds the 256 MiB raw chunk limit." % chunk_id}
		if codec == 0 and stored_length != raw_length:
			return {"error": "RAW chunk %d must have equal stored and raw lengths." % chunk_id}
		if file_offset % 16 != 0 or file_offset < payload_start:
			return {"error": "Chunk %d payload offset is not valid 16-byte aligned data storage." % chunk_id}
		if file_offset < previous_file_offset or file_offset > bytes.size() or stored_length > bytes.size() - file_offset:
			return {"error": "Chunk %d payload overlaps, is unsorted, or extends past the file." % chunk_id}
		if not _zero_range(bytes, previous_file_offset, file_offset):
			return {"error": "Non-zero padding precedes chunk %d." % chunk_id}
		if not KNOWN_CHUNK_TYPES.has(chunk_type) and entry_flags & 1 != 0:
			return {"unsupported": "ADM_ERR_UNSUPPORTED_CHUNK: unknown required chunk type %s." % chunk_type}
		var chunk := {
			"id": chunk_id,
			"type": chunk_type,
			"required": entry_flags & 1 != 0,
			"codec": codec,
			"file_offset": file_offset,
			"stored_length": stored_length,
			"raw_length": raw_length,
			"sha256": expected_hash,
			"referenced": false
		}
		chunks.append(chunk)
		public_chunks.append({
			"id": chunk_id,
			"type": chunk_type,
			"required": chunk.required,
			"codec": codec,
			"storedLength": stored_length,
			"rawLength": raw_length,
			"sha256": expected_hash
		})
		ids[chunk_id] = true
		previous_id = chunk_id
		previous_file_offset = file_offset + stored_length
	if bytes.size() > _align16(previous_file_offset) or not _zero_range(bytes, previous_file_offset, bytes.size()):
		return {"error": "Trailing bytes exceed alignment padding or contain non-zero data."}
	return {"chunks": chunks, "public_chunks": public_chunks}


static func _validate_manifest(manifest: Dictionary, magic: String, bytes: PackedByteArray, chunks: Array, result: Dictionary) -> String:
	var is_model := magic == "ADM0"
	var required_keys: Array = MODEL_REQUIRED if is_model else ANIM_REQUIRED
	var optional_keys: Array = MODEL_OPTIONAL if is_model else ANIM_OPTIONAL
	for key in required_keys:
		if not manifest.has(key):
			return "Manifest is missing required member '%s'." % key
	for key in manifest.keys():
		if not required_keys.has(key) and not optional_keys.has(key):
			return "Unknown top-level manifest member '%s' is invalid." % key
	if typeof(manifest.asset) != TYPE_DICTIONARY:
		return "'asset' must be an object."
	if manifest.asset.has("generator") and typeof(manifest.asset.generator) != TYPE_STRING:
		return "'asset.generator' must be a string."
	if manifest.asset.has("copyright") and typeof(manifest.asset.copyright) != TYPE_STRING:
		return "'asset.copyright' must be a string."

	for name in ["bufferViews", "accessors"]:
		if typeof(manifest[name]) != TYPE_ARRAY:
			return "'%s' must be an array." % name
	if is_model:
		for name in ["nodes", "scenes", "meshes"]:
			if typeof(manifest[name]) != TYPE_ARRAY:
				return "'%s' must be an array." % name
	else:
		if typeof(manifest.library) != TYPE_DICTIONARY or typeof(manifest.clips) != TYPE_ARRAY:
			return "'library' must be an object and 'clips' must be an array."
		var library_error := _validate_library(manifest.library)
		if not library_error.is_empty():
			return library_error
		var clip_error := _validate_clips(manifest.clips, manifest.library)
		if not clip_error.is_empty():
			return clip_error

	for optional_name in optional_keys:
		if manifest.has(optional_name) and optional_name in [
			"materials", "samplers", "images", "textures", "shaderDefinitions", "skins", "colliders",
			"lodGroups", "attachments", "skeletonProfiles", "facialProfiles", "expressions", "ikChains",
			"componentRoles", "chunkDependencies", "streamHints", "physicalMaterials", "hitboxes",
			"modelComponents", "modelProfiles", "extensionsUsed", "extensionsRequired", "clips",
			"bufferViews", "accessors", "nodes", "scenes", "meshes"
		] and typeof(manifest[optional_name]) != TYPE_ARRAY:
			return "'%s' must be an array." % optional_name
	if manifest.has("extras") and typeof(manifest.extras) != TYPE_DICTIONARY:
		return "'extras' must be an object."
	if manifest.has("extensions") and typeof(manifest.extensions) != TYPE_DICTIONARY:
		return "'extensions' must be an object."

	var extension_error := _validate_extensions(manifest, result)
	if not extension_error.is_empty():
		return extension_error
	var chunk_by_id := {}
	for chunk in chunks:
		chunk_by_id[chunk.id] = chunk
	var view_error := _validate_views(manifest.bufferViews, chunk_by_id)
	if not view_error.is_empty():
		return view_error
	for view in manifest.bufferViews:
		chunk_by_id[int(view.chunkId)].referenced = true
	var dependency_error := _validate_chunk_metadata(manifest, chunk_by_id)
	if not dependency_error.is_empty():
		return dependency_error
	var accessor_error := _validate_accessors(manifest.accessors, manifest.bufferViews, chunk_by_id, bytes)
	if not accessor_error.is_empty():
		return accessor_error
	for chunk in chunks:
		if not KNOWN_CHUNK_TYPES.has(chunk.type):
			if chunk.required or chunk.referenced:
				_add_unsupported(result, "ADM_ERR_UNSUPPORTED_CHUNK: needed chunk %d has unknown type %s." % [chunk.id, chunk.type])
			else:
				_add_diagnostic(result, "Unknown optional unreferenced chunk type %s was ignored." % chunk.type)
		if chunk.codec != 0 and chunk.required and not chunk.referenced:
			_add_unsupported(result, "Required chunk %d uses unavailable codec %d." % [chunk.id, chunk.codec])
	if is_model:
		var model_error := _validate_model_shape(manifest)
		if not model_error.is_empty():
			return model_error
		result.declared_capabilities.append("ADM-CORE-1")
		if not manifest.meshes.is_empty():
			result.declared_capabilities.append("triangle-mesh-data")
		if not manifest.get("materials", []).is_empty():
			result.declared_capabilities.append("ADM-SHADER-CORE-1")
		if not manifest.get("skins", []).is_empty():
			result.declared_capabilities.append("skinning")
		if not manifest.get("ikChains", []).is_empty():
			result.declared_capabilities.append("ADM-IK-1")
	else:
		result.declared_capabilities.append("ADM-ANIM-1")
		result.declared_capabilities.append("ADM-CONTAINER-1")
		for clip in manifest.clips:
			for channel in clip.get("channels", []):
				if typeof(channel) == TYPE_DICTIONARY and typeof(channel.get("target", null)) == TYPE_DICTIONARY:
					var channel_kind: String = str(channel.target.get("kind", "unknown"))
					_add_all_unique(result.declared_capabilities, ["animation-target:" + channel_kind])
	return ""


static func _validate_chunk_metadata(manifest: Dictionary, chunks: Dictionary) -> String:
	var dependencies := {}
	var incoming := {}
	for chunk_id in chunks:
		incoming[chunk_id] = 0
	for index in range(manifest.get("chunkDependencies", []).size()):
		var entry: Variant = manifest.chunkDependencies[index]
		if typeof(entry) != TYPE_DICTIONARY or entry.size() != 2 or not entry.has("chunkId") or not entry.has("requires") or typeof(entry.requires) != TYPE_ARRAY:
			return "chunkDependencies[%d] must contain only chunkId and a requires array." % index
		if not _is_uint(entry.chunkId) or not chunks.has(int(entry.chunkId)):
			return "chunkDependencies[%d] references an unknown chunkId." % index
		var chunk_id := int(entry.chunkId)
		if dependencies.has(chunk_id):
			return "chunkDependencies contains duplicate chunkId %d." % chunk_id
		var requires: Array = []
		var seen := {}
		for value in entry.requires:
			if not _is_uint(value) or not chunks.has(int(value)) or int(value) == chunk_id or seen.has(int(value)):
				return "chunkDependencies[%d] contains an invalid, duplicate, or self dependency." % index
			var required_id := int(value)
			seen[required_id] = true
			requires.append(required_id)
			incoming[required_id] += 1
		dependencies[chunk_id] = requires

	var ready: Array = []
	for chunk_id in incoming:
		if incoming[chunk_id] == 0:
			ready.append(chunk_id)
	var cursor := 0
	while cursor < ready.size():
		var chunk_id: int = ready[cursor]
		cursor += 1
		for required_id in dependencies.get(chunk_id, []):
			incoming[required_id] -= 1
			if incoming[required_id] == 0:
				ready.append(required_id)
	if ready.size() != chunks.size():
		return "chunkDependencies contains a cycle."

	ready.reverse()
	for chunk_id in ready:
		var available := true
		for required_id in dependencies.get(chunk_id, []):
			var prerequisite: Dictionary = chunks[required_id]
			if prerequisite.codec != 0 or not KNOWN_CHUNK_TYPES.has(prerequisite.type) or not prerequisite.dependencies_available:
				available = false
				break
		chunks[chunk_id].dependencies_available = available

	var needed: Array = []
	for chunk_id in chunks:
		if chunks[chunk_id].required or chunks[chunk_id].referenced:
			needed.append(chunk_id)
	var visited := {}
	cursor = 0
	while cursor < needed.size():
		var chunk_id: int = needed[cursor]
		cursor += 1
		if visited.has(chunk_id):
			continue
		visited[chunk_id] = true
		for required_id in dependencies.get(chunk_id, []):
			chunks[required_id].referenced = true
			needed.append(required_id)

	var hinted := {}
	for index in range(manifest.get("streamHints", []).size()):
		var hint: Variant = manifest.streamHints[index]
		if typeof(hint) != TYPE_DICTIONARY or hint.size() != 2 or not hint.has("chunkId") or not hint.has("priority"):
			return "streamHints[%d] must contain only chunkId and priority." % index
		if not _is_uint(hint.chunkId) or not chunks.has(int(hint.chunkId)) or hinted.has(int(hint.chunkId)):
			return "streamHints[%d] has an unknown or duplicate chunkId." % index
		if not _is_uint(hint.priority) or hint.priority > 255:
			return "streamHints[%d].priority must be in 0..255." % index
		hinted[int(hint.chunkId)] = true
	return ""


static func _validate_extensions(manifest: Dictionary, result: Dictionary) -> String:
	var used_value: Variant = manifest.get("extensionsUsed", [])
	var required_value: Variant = manifest.get("extensionsRequired", [])
	if typeof(used_value) != TYPE_ARRAY or typeof(required_value) != TYPE_ARRAY:
		return "'extensionsUsed' and 'extensionsRequired' must be arrays."
	var used: Array = used_value
	var required: Array = required_value
	var used_set := {}
	for extension_name in used:
		if typeof(extension_name) != TYPE_STRING or not _matches(extension_name, "^[A-Za-z][A-Za-z0-9_]*$"):
			return "'extensionsUsed' contains an invalid extension identifier."
		if used_set.has(extension_name):
			return "'extensionsUsed' contains duplicate identifier '%s'." % extension_name
		used_set[extension_name] = true
	for extension_name in required:
		if typeof(extension_name) != TYPE_STRING or not used_set.has(extension_name):
			return "'extensionsRequired' must contain unique members of 'extensionsUsed'."
		if result.declared_capabilities.has("required-extension:" + extension_name):
			return "'extensionsRequired' contains duplicate identifier '%s'." % extension_name
		result.declared_capabilities.append("required-extension:" + extension_name)
	_add_all_unique(result.declared_capabilities, used.map(func(value): return "extension:" + str(value)))
	var extension_data: Dictionary = manifest.get("extensions", {})
	for name in extension_data.keys():
		if not used_set.has(name):
			return "Extension data '%s' is missing from 'extensionsUsed'." % name
	for name in required:
		_add_unsupported(result, "Required extension '%s' is not implemented by this validation milestone." % name)
	for name in used:
		if not required.has(name):
			_add_diagnostic(result, "Optional extension '%s' metadata is preserved but not interpreted." % name)
	return ""


static func _validate_views(views: Array, chunks: Dictionary) -> String:
	for index in range(views.size()):
		var view: Variant = views[index]
		if typeof(view) != TYPE_DICTIONARY or not view.has("chunkId") or not view.has("byteOffset") or not view.has("byteLength"):
			return "bufferViews[%d] must have chunkId, byteOffset, and byteLength." % index
		if not _is_uint(view.chunkId) or not _is_uint(view.byteOffset) or not _is_uint(view.byteLength):
			return "bufferViews[%d] fields must be unsigned integers." % index
		var chunk_id := int(view.chunkId)
		if not chunks.has(chunk_id):
			return "bufferViews[%d] references unknown chunk %d." % [index, view.chunkId]
		var chunk: Dictionary = chunks[chunk_id]
		if not KNOWN_CHUNK_TYPES.has(chunk.type):
			return "UNSUPPORTED:bufferViews[%d] references unknown chunk type %s." % [index, chunk.type]
		if view.byteOffset + view.byteLength > chunk.raw_length:
			return "bufferViews[%d] exceeds the decompressed chunk bounds." % index
	return ""


static func _validate_accessors(accessors: Array, views: Array, chunks: Dictionary, bytes: PackedByteArray) -> String:
	for index in range(accessors.size()):
		var accessor: Variant = accessors[index]
		if typeof(accessor) != TYPE_DICTIONARY:
			return "accessors[%d] must be an object." % index
		for key in ["bufferView", "componentType", "type", "count"]:
			if not accessor.has(key):
				return "accessors[%d] is missing '%s'." % [index, key]
		if not _is_uint(accessor.bufferView) or accessor.bufferView >= views.size():
			return "accessors[%d] references a nonexistent bufferView." % index
		if not _is_uint(accessor.count):
			return "accessors[%d].count must be a u32." % index
		if not COMPONENT_SIZES.has(accessor.componentType) or not COMPONENT_COUNTS.has(accessor.type):
			return "accessors[%d] has an unsupported component type or shape." % index
		if accessor.has("normalized") and typeof(accessor.normalized) != TYPE_BOOL:
			return "accessors[%d].normalized must be boolean." % index
		var component_size: int = COMPONENT_SIZES[accessor.componentType]
		var byte_offset: int = accessor.get("byteOffset", 0)
		if not _is_uint(byte_offset) or byte_offset % component_size != 0:
			return "accessors[%d] has an invalid or unaligned byteOffset." % index
		var element_count: int = COMPONENT_COUNTS[accessor.type]
		var byte_count := int(accessor.count) * element_count * component_size
		var view: Dictionary = views[int(accessor.bufferView)]
		if byte_offset + byte_count > view.byteLength:
			return "accessors[%d] exceeds its declared bufferView range." % index
		var chunk: Dictionary = chunks[int(view.chunkId)]
		if chunk.codec != 0 or not chunk.dependencies_available:
			continue
		if accessor.componentType == "F32":
			var accessor_start: int = chunk.file_offset + view.byteOffset + byte_offset
			for value_index in range(int(accessor.count) * element_count):
				if not is_finite(bytes.decode_float(accessor_start + value_index * component_size)):
					return "accessors[%d] contains a non-finite F32 value." % index
	return ""


static func _validate_model_shape(manifest: Dictionary) -> String:
	if manifest.scenes.is_empty():
		return "'scenes' must contain at least one scene."
	if not _is_uint(manifest.scene) or manifest.scene >= manifest.scenes.size():
		return "'scene' must reference an existing scene."
	for index in range(manifest.scenes.size()):
		var scene: Variant = manifest.scenes[index]
		if typeof(scene) != TYPE_DICTIONARY or not scene.has("nodes") or typeof(scene.nodes) != TYPE_ARRAY:
			return "scenes[%d] must contain a nodes array." % index
	for index in range(manifest.nodes.size()):
		var node: Variant = manifest.nodes[index]
		if typeof(node) != TYPE_DICTIONARY:
			return "nodes[%d] must be an object." % index
		if node.has("children") and typeof(node.children) != TYPE_ARRAY:
			return "nodes[%d].children must be an array." % index
		for key in ["mesh", "skin"]:
			if node.has(key):
				var collection: Array = manifest.meshes if key == "mesh" else manifest.get("skins", [])
				if not _is_uint(node[key]) or node[key] >= collection.size():
					return "nodes[%d].%s references a nonexistent item." % [index, key]
		if node.has("skin") and not node.has("mesh"):
			return "nodes[%d] has a skin without a mesh." % index
	for index in range(manifest.meshes.size()):
		var mesh: Variant = manifest.meshes[index]
		if typeof(mesh) != TYPE_DICTIONARY or not mesh.has("primitives") or typeof(mesh.primitives) != TYPE_ARRAY or mesh.primitives.is_empty():
			return "meshes[%d] must contain at least one primitive." % index
	return ""


static func _validate_library(library: Dictionary) -> String:
	for key in ["id", "title", "description", "language", "targetProfile", "binding"]:
		if not library.has(key) or typeof(library[key]) != TYPE_STRING:
			return "Animation library is missing a required string member '%s'." % key
	if not _matches(library.id, "^[a-z][a-z0-9_]*(@[a-z][a-z0-9_]*)*$"):
		return "library.id does not follow the ADM animation library identifier syntax."
	if library.title.strip_edges().is_empty() or library.title.length() > 256:
		return "library.title must contain 1..256 non-whitespace characters."
	if library.description.strip_edges().is_empty() or library.description.length() > 2048:
		return "library.description must contain 1..2048 non-whitespace characters."
	if library.binding != "SEMANTIC" and library.binding != "EXACT":
		return "library.binding must be SEMANTIC or EXACT."
	if library.binding == "EXACT" and (not library.has("rigId") or typeof(library.rigId) != TYPE_STRING):
		return "EXACT animation library binding requires rigId."
	if library.binding == "SEMANTIC" and library.has("rigId"):
		return "SEMANTIC animation library binding must not include rigId."
	if library.has("sourceHeight") and not library.has("motionScale"):
		return "library.sourceHeight without motionScale is invalid."
	if library.has("motionScale") and library.motionScale != "SOURCE_HEIGHT":
		return "library.motionScale must be SOURCE_HEIGHT when specified."
	return ""


static func _validate_clips(clips: Array, library: Dictionary) -> String:
	var seen := {}
	for index in range(clips.size()):
		var clip: Variant = clips[index]
		if typeof(clip) != TYPE_DICTIONARY:
			return "clips[%d] must be an object." % index
		for key in ["id", "title", "description", "language", "duration", "loop", "rootMotion", "channels", "samplers"]:
			if not clip.has(key):
				return "clips[%d] is missing required member '%s'." % [index, key]
		if typeof(clip.id) != TYPE_STRING or not _matches(clip.id, "^[a-z][a-z0-9_]*$") or seen.has(clip.id):
			return "clips[%d] has an invalid or duplicate id." % index
		seen[clip.id] = true
		if typeof(clip.title) != TYPE_STRING or clip.title.strip_edges().is_empty() or clip.title.length() > 256:
			return "clips[%d].title must contain 1..256 non-whitespace characters." % index
		if typeof(clip.description) != TYPE_STRING or clip.description.strip_edges().is_empty() or clip.description.length() > 2048:
			return "clips[%d].description must contain 1..2048 non-whitespace characters." % index
		if typeof(clip.duration) != TYPE_FLOAT and typeof(clip.duration) != TYPE_INT:
			return "clips[%d].duration must be a finite nonnegative number." % index
		if not is_finite(float(clip.duration)) or clip.duration < 0:
			return "clips[%d].duration must be a finite nonnegative number." % index
		if not ["ONCE", "REPEAT", "PINGPONG"].has(clip.loop):
			return "clips[%d].loop is invalid." % index
		if not ["IN_PLACE", "EXTRACT", "IGNORE"].has(clip.rootMotion):
			return "clips[%d].rootMotion is invalid." % index
		if typeof(clip.channels) != TYPE_ARRAY or typeof(clip.samplers) != TYPE_ARRAY:
			return "clips[%d].channels and samplers must be arrays." % index
		if clip.rootMotion == "EXTRACT" and not library.has("rootMotionSource"):
			return "EXTRACT clip '%s' requires library.rootMotionSource." % clip.id
	return ""


static func _base_result(source_name: String, bytes: PackedByteArray) -> Dictionary:
	return {
		"status": "invalid",
		"source": source_name,
		"assetSha256": _sha256(bytes),
		"runtimeStatus": "unsupported",
		"runtimeLimitations": ["Full ADM runtime is not implemented; a diagnostic geometry preview is available separately."],
		"specification": {"version": "ADM 1.0", "commit": SPEC_SHA, "url": SPEC_URL},
		"capabilities": {
			"implemented": IMPLEMENTED_CAPABILITIES.duplicate(),
			"declared": [],
			"notes": ["Validation is partial; the diagnostic preview supports some PNG/JPEG textures but is not a full ADM renderer. Animation evaluation and IK solving are unsupported."]
		},
		"declared_capabilities": [],
		"unsupported": [],
		"deviations": [],
		"diagnostics": [],
		"chunks": [],
		"manifest": {}
	}


static func _invalid(source_name: String, message: String) -> Dictionary:
	var result := _base_result(source_name, PackedByteArray())
	return _finish_invalid(result, message)


static func _finish_invalid(result: Dictionary, message: String) -> Dictionary:
	result.status = "invalid"
	_add_diagnostic(result, message)
	result.capabilities.declared = result.declared_capabilities
	result.deviations = result.unsupported.duplicate()
	return result


static func _add_diagnostic(result: Dictionary, message: String) -> void:
	result.diagnostics.append(message)


static func _add_unsupported(result: Dictionary, message: String) -> void:
	if not result.unsupported.has(message):
		result.unsupported.append(message)


static func _add_all_unique(target: Array, values: Array) -> void:
	for value in values:
		if not target.has(value):
			target.append(value)


static func _align16(value: int) -> int:
	return (value + 15) & ~15


static func _zero_range(bytes: PackedByteArray, start: int, end: int) -> bool:
	if start < 0 or end < start or end > bytes.size():
		return false
	for index in range(start, end):
		if bytes[index] != 0:
			return false
	return true


static func _ascii(bytes: PackedByteArray, offset: int, length: int) -> String:
	return bytes.slice(offset, offset + length).get_string_from_ascii()


static func _u16(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8)


static func _u32(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)


static func _u64(bytes: PackedByteArray, offset: int) -> int:
	var value := 0
	for index in range(8):
		value |= bytes[offset + index] << (index * 8)
	return value


static func _hex(bytes: PackedByteArray) -> String:
	var value := ""
	for byte in bytes:
		value += "%02x" % byte
	return value


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return _hex(context.finish())


static func _find_duplicate_json_key(json_text: String) -> Dictionary:
	var object_keys: Array[Dictionary] = []
	var index := 0
	while index < json_text.length():
		var character := json_text.substr(index, 1)
		if character == "\"":
			var start := index
			index += 1
			var escaped := false
			while index < json_text.length():
				character = json_text.substr(index, 1)
				if escaped:
					escaped = false
				elif character == "\\":
					escaped = true
				elif character == "\"":
					break
				index += 1
			if index >= json_text.length():
				break
			var token := json_text.substr(start, index - start + 1)
			var next_index := index + 1
			while next_index < json_text.length() and json_text.substr(next_index, 1).strip_edges().is_empty():
				next_index += 1
			if next_index < json_text.length() and json_text.substr(next_index, 1) == ":" and not object_keys.is_empty():
				var key: Variant = JSON.parse_string(token)
				if typeof(key) == TYPE_STRING:
					var current_keys: Dictionary = object_keys.back()
					if current_keys.has(key):
						return {"found": true, "key": key}
					current_keys[key] = true
					object_keys[object_keys.size() - 1] = current_keys
			index += 1
			continue
		if character == "{":
			object_keys.append({})
		elif character == "}" and not object_keys.is_empty():
			object_keys.pop_back()
		index += 1
	return {"found": false, "key": ""}


static func _is_uint(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return value >= 0 and value <= 4294967295
	if typeof(value) == TYPE_FLOAT:
		return is_finite(value) and value >= 0.0 and value <= 4294967295.0 and floor(value) == value
	return false


static func _matches(value: String, expression: String) -> bool:
	var regex := RegEx.new()
	var compile_error := regex.compile(expression)
	if compile_error != OK:
		return false
	return regex.search(value) != null
