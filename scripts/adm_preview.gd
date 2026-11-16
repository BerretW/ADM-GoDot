extends RefCounted

const Validator = preload("res://scripts/adm_validator.gd")
const MAX_VERTICES := 1000000
const MAX_INDICES := 3000000
const MAX_SCENE_NODES := 100000
const MAX_IMAGE_DIMENSION := 8192
const MAX_IMAGE_PIXELS := 16777216


static func load_path(path: String, diagnostic: bool = false) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "Soubor nelze otevřít: %s" % error_string(FileAccess.get_open_error())}
	if file.get_length() > Validator.MAX_FILE_SIZE:
		return {"error": "Soubor překračuje limit 1 GiB."}
	var bytes := file.get_buffer(file.get_length())
	var report: Dictionary = Validator.inspect_bytes(bytes, path.get_file())
	if report.status == "invalid":
		return {"error": "Neplatný ADM: %s" % "; ".join(report.diagnostics), "report": report}
	if not path.to_lower().ends_with(".adm"):
		return {"error": "Animační knihovna neobsahuje geometrii modelu.", "report": report}
	if report.status == "unsupported" and not diagnostic:
		return {"error": "Model vyžaduje nepodporované funkce. Pro neúplný náhled zapněte diagnostický režim.", "report": report}
	if report.manifest.is_empty():
		return {"error": "Manifest není dostupný pro náhled.", "report": report}
	# Diagnostic mode never bypasses integrity or codec checks for geometry.
	for problem in report.unsupported:
		if not problem.begins_with("Required extension '"):
			return {"error": "Náhled nelze načíst: %s" % problem, "report": report}
	return build(bytes, report, diagnostic)


static func build(bytes: PackedByteArray, report: Dictionary, diagnostic: bool) -> Dictionary:
	var manifest: Dictionary = report.manifest
	var chunks := {}
	var directory_offset := Validator._u64(bytes, 40)
	var chunk_count := Validator._u32(bytes, 48)
	for index in range(chunk_count):
		var entry: int = directory_offset + index * 80
		chunks[Validator._u64(bytes, entry)] = {
			"codec": Validator._u32(bytes, entry + 16),
			"offset": Validator._u64(bytes, entry + 24),
			"type": Validator._ascii(bytes, entry + 8, 4)
		}
	var root := Node3D.new()
	root.name = "ADMModel"
	var warnings: Array[String] = [
		"Diagnostický náhled: statická geometrie a částečný materiálový fallback; nejde o úplný PBR render.",
		"Pokročilé shadery, další texturové kanály, vertex barvy, morph, skinning, animace, IK a kolize nejsou vykresleny.",
		"Pokud normály chybí, jsou dopočítány pro náhled; nasvícení a průhlednost nejsou přesná implementace ADM."
	]
	var material_info: Array = []
	var texture_cache := {}
	if diagnostic and report.status == "unsupported":
		warnings.append("POZOR: povinná rozšíření nejsou podporována; model nebyl přijat jako kompatibilní.")
	var roots: Array = manifest.scenes[int(manifest.scene)].nodes
	var pending: Array = []
	for root_index in roots:
		pending.append({"index": root_index, "parent": root, "world": Transform3D.IDENTITY})
	var seen := {}
	var bounds := AABB()
	var has_bounds := false
	var mesh_count := 0
	var vertex_total := 0
	var triangle_total := 0
	while not pending.is_empty():
		var item: Dictionary = pending.pop_back()
		if not _index(item.index, manifest.nodes.size()) or seen.has(int(item.index)):
			root.free()
			return {"error": "Neplatná hierarchie: neexistující, opakovaný nebo cyklický uzel.", "report": report}
		var node_index := int(item.index)
		seen[node_index] = true
		if seen.size() > MAX_SCENE_NODES:
			root.free()
			return {"error": "Scéna překračuje limit uzlů náhledu.", "report": report}
		var data: Dictionary = manifest.nodes[node_index]
		var transform_result := _transform(data)
		if transform_result.has("error"):
			root.free()
			return {"error": "Uzel %d: %s" % [node_index, transform_result.error], "report": report}
		var node := Node3D.new()
		node.name = "Node_%d" % node_index
		node.transform = transform_result.value
		item.parent.add_child(node)
		var world: Transform3D = item.world * node.transform
		if data.has("mesh"):
			var mesh: Dictionary = manifest.meshes[int(data.mesh)]
			for primitive in mesh.primitives:
				var built := _primitive(primitive, manifest, chunks, bytes, MAX_VERTICES - vertex_total, MAX_INDICES - triangle_total * 3, texture_cache)
				if built.has("error"):
					root.free()
					return {"error": "Uzel %d: %s" % [node_index, built.error], "report": report}
				var instance := MeshInstance3D.new()
				instance.mesh = built.mesh
				node.add_child(instance)
				mesh_count += 1
				vertex_total += built.vertices.size()
				triangle_total += built.triangles
				for message in built.warnings:
					if not warnings.has(message):
						warnings.append(message)
				if not material_info.has(built.material_info):
					material_info.append(built.material_info)
				for vertex in built.vertices:
					var point: Vector3 = world * vertex
					if not has_bounds:
						bounds = AABB(point, Vector3.ZERO)
						has_bounds = true
					else:
						bounds = bounds.expand(point)
		for child in data.get("children", []):
			pending.append({"index": child, "parent": node, "world": world})
	if not has_bounds:
		root.free()
		return {"error": "Výchozí scéna neobsahuje zobrazitelnou geometrii.", "report": report}
	report.runtimeStatus = "unsupported"
	report.runtimeLimitations = warnings
	report.preview = {
		"status": "diagnostic_only", "meshPrimitives": mesh_count,
		"vertices": vertex_total, "triangles": triangle_total,
		"boundsMin": [bounds.position.x, bounds.position.y, bounds.position.z],
		"boundsMax": [bounds.end.x, bounds.end.y, bounds.end.z],
		"diagnosticOverride": diagnostic and report.status == "unsupported",
		"limitations": warnings, "materials": material_info
	}
	return {"root": root, "bounds": bounds, "report": report}


static func _primitive(primitive: Variant, manifest: Dictionary, chunks: Dictionary, bytes: PackedByteArray, vertex_limit: int, index_limit: int, texture_cache: Dictionary) -> Dictionary:
	if typeof(primitive) != TYPE_DICTIONARY or typeof(primitive.get("attributes")) != TYPE_DICTIONARY:
		return {"error": "Neplatná primitiva nebo atributy."}
	if not primitive.attributes.has("POSITION") or not primitive.has("indices"):
		return {"error": "Primitivě chybí POSITION nebo indices."}
	var position := _accessor(primitive.attributes.POSITION, "F32", "VEC3", manifest, chunks, bytes, vertex_limit)
	if position.has("error"):
		return position
	var indices_result := _accessor(primitive.indices, "INDEX", "SCALAR", manifest, chunks, bytes, index_limit)
	if indices_result.has("error"):
		return indices_result
	var vertices := PackedVector3Array()
	var pa: Dictionary = position.accessor
	for index in range(int(pa.count)):
		var offset: int = position.offset + index * 12
		vertices.append(Vector3(bytes.decode_float(offset), bytes.decode_float(offset + 4), bytes.decode_float(offset + 8)))
	if vertices.size() < 3 or int(indices_result.accessor.count) < 3 or int(indices_result.accessor.count) % 3 != 0:
		return {"error": "Primitiva nemá platný počet vrcholů nebo trojúhelníků."}
	var indices := PackedInt32Array()
	var ia: Dictionary = indices_result.accessor
	var step: int = 2 if ia.componentType == "U16" else 4
	for index in range(int(ia.count)):
		var at: int = indices_result.offset + index * step
		var value: int = bytes.decode_u16(at) if step == 2 else bytes.decode_u32(at)
		if value >= vertices.size():
			return {"error": "Index vrcholu %d je mimo rozsah." % value}
		indices.append(value)
	# ADM front faces are CCW; Godot's front faces use clockwise winding.
	for index in range(0, indices.size(), 3):
		var previous := indices[index + 1]
		indices[index + 1] = indices[index + 2]
		indices[index + 2] = previous
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var normals := PackedVector3Array()
	if primitive.attributes.has("NORMAL"):
		var normal_result := _accessor(primitive.attributes.NORMAL, "F32", "VEC3", manifest, chunks, bytes, vertex_limit)
		if normal_result.has("error"):
			return normal_result
		if int(normal_result.accessor.count) != vertices.size():
			return {"error": "Počet normál neodpovídá počtu vrcholů."}
		for index in range(vertices.size()):
			var at: int = normal_result.offset + index * 12
			var normal := Vector3(bytes.decode_float(at), bytes.decode_float(at + 4), bytes.decode_float(at + 8))
			if not normal.is_finite() or normal.length_squared() < 0.000000000001:
				return {"error": "Primitiva obsahuje neplatnou normálu."}
			normals.append(normal.normalized())
	else:
		normals.resize(vertices.size())
		for index in range(0, indices.size(), 3):
			var a := indices[index]
			var b := indices[index + 1]
			var c := indices[index + 2]
			var face := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
			normals[a] += face
			normals[b] += face
			normals[c] += face
		for index in range(normals.size()):
			normals[index] = normals[index].normalized() if normals[index].length_squared() > 0.000000000001 else Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = normals
	var material := StandardMaterial3D.new()
	var warnings: Array[String] = []
	var info := {"materialIndex": -1, "shaderId": "adm.pbr.metallic_roughness", "shaderVersion": "1.0.0", "shaderSupported": false, "shaderFallbackActive": true, "baseColorTexture": "absent"}
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if primitive.has("material"):
		var materials: Array = manifest.get("materials", [])
		if not _index(primitive.material, materials.size()) or typeof(materials[int(primitive.material)]) != TYPE_DICTIONARY:
			return {"error": "Primitiva odkazuje na neexistující materiál."}
		var data: Dictionary = materials[int(primitive.material)]
		info.materialIndex = int(primitive.material)
		var shader: Variant = data.get("shader", {"id": "adm.pbr.metallic_roughness", "version": "1.0.0"})
		if typeof(shader) != TYPE_DICTIONARY or typeof(shader.get("id")) != TYPE_STRING or typeof(shader.get("version")) != TYPE_STRING:
			return {"error": "Neplatná identita shaderu materiálu."}
		info.shaderId = shader.id
		info.shaderVersion = shader.version
		if shader.id != "adm.pbr.metallic_roughness" or shader.version != "1.0.0":
			warnings.append("Shader %s@%s není podporován; používá se neúplný PBR fallback." % [shader.id, shader.version])
		var color: Variant = data.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
		if not _numbers(color, 4):
			return {"error": "Neplatná baseColorFactor."}
		for component in color:
			if component < 0 or component > 1:
				return {"error": "baseColorFactor je mimo rozsah [0,1]."}
		material.albedo_color = Color(color[0], color[1], color[2], color[3]).linear_to_srgb()
		for field in ["metallicFactor", "roughnessFactor"]:
			var value: Variant = data.get(field, 1.0)
			if (typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT) or not is_finite(float(value)) or value < 0 or value > 1:
				return {"error": "Neplatný %s." % field}
		material.metallic = float(data.get("metallicFactor", 1.0))
		material.roughness = float(data.get("roughnessFactor", 1.0))
		var alpha_mode: Variant = data.get("alphaMode", "OPAQUE")
		if alpha_mode == "BLEND":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		elif alpha_mode == "MASK":
			var cutoff: Variant = data.get("alphaCutoff", 0.5)
			if (typeof(cutoff) != TYPE_INT and typeof(cutoff) != TYPE_FLOAT) or not is_finite(float(cutoff)) or cutoff < 0 or cutoff > 1:
				return {"error": "Neplatný alphaCutoff."}
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = float(cutoff)
		elif alpha_mode != "OPAQUE":
			return {"error": "Neplatný alphaMode."}
		for field in ["metallicRoughnessTexture", "normalTexture", "occlusionTexture", "emissiveTexture", "emissiveFactor"]:
			if data.has(field) and (field != "emissiveFactor" or data[field] != [0.0, 0.0, 0.0]):
				warnings.append("Materiál %d: %s zatím není vykreslen." % [int(primitive.material), field])
		if data.has("baseColorTexture"):
			var binding := _base_texture(data.baseColorTexture, primitive.attributes, vertices.size(), manifest, chunks, bytes, texture_cache)
			if binding.has("error"):
				return binding
			if binding.has("warning"):
				info.baseColorTexture = "unsupported"
				warnings.append("Materiál %d: %s" % [int(primitive.material), binding.warning])
			else:
				arrays[Mesh.ARRAY_TEX_UV] = binding.uv
				material.albedo_texture = binding.texture
				material.texture_repeat = binding.repeat
				material.texture_filter = binding.filter
				info.baseColorTexture = "png_jpeg"
	else:
		material.roughness = 1.0
		material.metallic = 1.0
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	array_mesh.surface_set_material(0, material)
	return {"mesh": array_mesh, "vertices": vertices, "triangles": indices.size() / 3, "warnings": warnings, "material_info": info}


static func _base_texture(binding: Variant, attributes: Dictionary, vertex_count: int, manifest: Dictionary, chunks: Dictionary, bytes: PackedByteArray, cache: Dictionary) -> Dictionary:
	var textures: Array = manifest.get("textures", [])
	var images: Array = manifest.get("images", [])
	if typeof(binding) != TYPE_DICTIONARY or not binding.has("index") or not _index(binding.index, textures.size()):
		return {"error": "baseColorTexture odkazuje na neexistující texturu."}
	var texcoord: Variant = binding.get("texCoord", 0)
	if not Validator._is_uint(texcoord) or int(texcoord) > 1:
		return {"error": "baseColorTexture má neplatný texCoord."}
	var semantic := "TEXCOORD_%d" % int(texcoord)
	if not attributes.has(semantic):
		return {"error": "baseColorTexture vyžaduje chybějící %s." % semantic}
	var uv_accessor := _accessor(attributes[semantic], "F32", "VEC2", manifest, chunks, bytes, vertex_count)
	if uv_accessor.has("error"):
		return uv_accessor
	if int(uv_accessor.accessor.count) != vertex_count:
		return {"error": "Počet UV souřadnic neodpovídá počtu vrcholů."}
	var texture: Variant = textures[int(binding.index)]
	if typeof(texture) != TYPE_DICTIONARY or not texture.has("source") or not _index(texture.source, images.size()):
		return {"error": "Textura odkazuje na neexistující obrázek."}
	var sampler := {}
	if texture.has("sampler"):
		var samplers: Array = manifest.get("samplers", [])
		if not _index(texture.sampler, samplers.size()) or typeof(samplers[int(texture.sampler)]) != TYPE_DICTIONARY:
			return {"error": "Textura odkazuje na neexistující sampler."}
		sampler = samplers[int(texture.sampler)]
	var wrap_s: Variant = sampler.get("wrapS", "REPEAT")
	var wrap_t: Variant = sampler.get("wrapT", "REPEAT")
	var min_filter: Variant = sampler.get("minFilter", "LINEAR")
	var mag_filter: Variant = sampler.get("magFilter", "LINEAR")
	if not ["REPEAT", "CLAMP_TO_EDGE", "MIRRORED_REPEAT"].has(wrap_s) or not ["REPEAT", "CLAMP_TO_EDGE", "MIRRORED_REPEAT"].has(wrap_t) or not ["LINEAR", "NEAREST"].has(min_filter) or not ["LINEAR", "NEAREST"].has(mag_filter):
		return {"error": "Textura má neplatný sampler."}
	if wrap_s != wrap_t or wrap_s == "MIRRORED_REPEAT" or min_filter != mag_filter:
		return {"warning": "Kombinace sampleru základní textury zatím není podporována; textura není zobrazena."}
	var image_index := int(texture.source)
	var image_data: Variant = images[image_index]
	if typeof(image_data) != TYPE_DICTIONARY or not image_data.has("mimeType"):
		return {"error": "Obrázek nemá platný mimeType."}
	if image_data.mimeType == "image/ktx2" or image_data.mimeType == "image/vnd-ms.dds":
		return {"warning": "KTX2/DDS a jejich fallback zatím nejsou v náhledu podporovány."}
	if image_data.mimeType != "image/png" and image_data.mimeType != "image/jpeg":
		return {"error": "Nepovolený mimeType obrázku."}
	if not image_data.has("bufferView") or not _index(image_data.bufferView, manifest.bufferViews.size()):
		return {"error": "Obrázek odkazuje na neexistující bufferView."}
	var view: Dictionary = manifest.bufferViews[int(image_data.bufferView)]
	var chunk: Dictionary = chunks[int(view.chunkId)]
	if chunk.type != "IMAG":
		return {"error": "Obrázek musí odkazovat na IMAG chunk."}
	if chunk.codec != 0:
		return {"warning": "Obrázek používá nepodporovanou kompresi chunku."}
	var uv := PackedVector2Array()
	for index in range(vertex_count):
		var offset: int = uv_accessor.offset + index * 8
		uv.append(Vector2(bytes.decode_float(offset), bytes.decode_float(offset + 4)))
	if not cache.has(image_index):
		var start: int = chunk.offset + int(view.byteOffset)
		var encoded := bytes.slice(start, start + int(view.byteLength))
		var dimensions := _image_dimensions(encoded, image_data.mimeType)
		if dimensions.x <= 0 or dimensions.y <= 0:
			return {"error": "Obrázek nemá platnou hlavičku odpovídající mimeType."}
		if dimensions.x > MAX_IMAGE_DIMENSION or dimensions.y > MAX_IMAGE_DIMENSION or dimensions.x * dimensions.y > MAX_IMAGE_PIXELS:
			return {"warning": "Obrázek překračuje limit velikosti náhledu."}
		var image := Image.new()
		var status: Error = image.load_png_from_buffer(encoded) if image_data.mimeType == "image/png" else image.load_jpg_from_buffer(encoded)
		if status != OK or image.is_empty() or image.get_width() != dimensions.x or image.get_height() != dimensions.y:
			return {"error": "Obrázek nelze dekódovat: %s." % error_string(status)}
		cache[image_index] = ImageTexture.create_from_image(image)
	return {"uv": uv, "texture": cache[image_index], "repeat": wrap_s == "REPEAT",
		"filter": BaseMaterial3D.TEXTURE_FILTER_NEAREST if min_filter == "NEAREST" else BaseMaterial3D.TEXTURE_FILTER_LINEAR}


static func _image_dimensions(data: PackedByteArray, mime: String) -> Vector2i:
	if mime == "image/png":
		if data.size() < 24 or data.slice(0, 8) != PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]) or data.slice(12, 16).get_string_from_ascii() != "IHDR":
			return Vector2i.ZERO
		return Vector2i(_be32(data, 16), _be32(data, 20))
	if data.size() < 4 or data[0] != 255 or data[1] != 216:
		return Vector2i.ZERO
	var index := 2
	while index + 3 < data.size():
		if data[index] != 255:
			return Vector2i.ZERO
		while index < data.size() and data[index] == 255:
			index += 1
		if index >= data.size():
			break
		var marker := data[index]
		index += 1
		if marker == 217 or marker == 218:
			break
		if marker == 1 or (marker >= 208 and marker <= 215):
			continue
		if index + 1 >= data.size():
			break
		var length: int = (data[index] << 8) | data[index + 1]
		if length < 2 or index + length > data.size():
			break
		if marker == 192 and length >= 8:
			return Vector2i((data[index + 5] << 8) | data[index + 6], (data[index + 3] << 8) | data[index + 4])
		index += length
	return Vector2i.ZERO


static func _be32(data: PackedByteArray, offset: int) -> int:
	return (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]


static func _accessor(index: Variant, component: String, shape: String, manifest: Dictionary, chunks: Dictionary, bytes: PackedByteArray, limit: int) -> Dictionary:
	if not _index(index, manifest.accessors.size()):
		return {"error": "Atribut odkazuje na neexistující accessor."}
	var accessor: Dictionary = manifest.accessors[int(index)]
	if accessor.type != shape or (component == "INDEX" and not ["U16", "U32"].has(accessor.componentType)) or (component != "INDEX" and accessor.componentType != component) or accessor.get("normalized", false):
		return {"error": "Nepodporovaný nebo neplatný formát accessor %d." % int(index)}
	if int(accessor.count) > limit:
		return {"error": "Geometrie překračuje limit náhledu."}
	var view: Dictionary = manifest.bufferViews[int(accessor.bufferView)]
	var chunk: Dictionary = chunks[int(view.chunkId)]
	if chunk.codec != 0:
		return {"error": "Geometrie vyžaduje nepodporovanou kompresi."}
	var offset: int = chunk.offset + int(view.byteOffset) + int(accessor.get("byteOffset", 0))
	if offset < 0 or offset >= bytes.size():
		return {"error": "Accessor začíná mimo soubor."}
	return {"accessor": accessor, "offset": offset}


static func _index(value: Variant, length: int) -> bool:
	return Validator._is_uint(value) and int(value) < length


static func _numbers(value: Variant, count: int) -> bool:
	if typeof(value) != TYPE_ARRAY or value.size() != count:
		return false
	for number in value:
		if (typeof(number) != TYPE_INT and typeof(number) != TYPE_FLOAT) or not is_finite(float(number)):
			return false
	return true


static func _transform(data: Dictionary) -> Dictionary:
	if data.has("matrix"):
		var m: Variant = data.matrix
		if not _numbers(m, 16) or data.has("translation") or data.has("rotation") or data.has("scale"):
			return {"error": "Neplatná matice nebo současné použití matice a TRS."}
		if m[3] != 0 or m[7] != 0 or m[11] != 0 or m[15] != 1:
			return {"error": "Transformace není afinní."}
		return {"value": Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])), Vector3(m[12], m[13], m[14]))}
	var t: Variant = data.get("translation", [0, 0, 0])
	var r: Variant = data.get("rotation", [0, 0, 0, 1])
	var s: Variant = data.get("scale", [1, 1, 1])
	if not _numbers(t, 3) or not _numbers(r, 4) or not _numbers(s, 3):
		return {"error": "Neplatná TRS transformace."}
	var q := Quaternion(r[0], r[1], r[2], r[3])
	if abs(q.length() - 1.0) > 0.0001:
		return {"error": "Kvaternion není normalizovaný."}
	var basis := Basis(q.normalized()).scaled_local(Vector3(s[0], s[1], s[2]))
	return {"value": Transform3D(basis, Vector3(t[0], t[1], t[2]))}
