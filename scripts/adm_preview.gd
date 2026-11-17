extends RefCounted

const Validator = preload("res://scripts/adm_validator.gd")
const MAX_VERTICES := 1000000
const MAX_INDICES := 3000000
const MAX_SCENE_NODES := 100000
const MAX_IMAGE_DIMENSION := 8192
const MAX_IMAGE_PIXELS := 16777216
const JOINT_DISPLAY_EXTENSION := "ADM_joint_display_v1"
const DETAIL_SHADER = preload("res://scripts/adm_detail_preview.gdshader")


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
	var displays := _joint_displays(manifest)
	if displays.has("error"):
		if displays.get("invalid", false):
			report.status = "invalid"
			report.diagnostics.append(displays.error)
			report.deviations.append(displays.error)
		return {"error": displays.error, "report": report}
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
		"Pokročilé shadery, normal/metallic/roughness/occlusion textury, vertex barvy, morph, skinning, animace, IK a kolize nejsou vykresleny.",
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
	var joint_vertices := PackedVector3Array()
	var joint_colors := PackedColorArray()
	var joint_count := 0
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
		if displays.nodes.has(node_index):
			var display: Dictionary = displays.nodes[node_index]
			var frame: Transform3D = world * display.frame
			var head: Vector3 = frame.origin
			var tail: Vector3 = frame * display.tail
			if not head.is_finite() or not tail.is_finite() or not frame.basis.is_finite():
				root.free()
				return {"error": "Uzel %d: rámec kloubu překračuje číselný rozsah náhledu." % node_index, "report": report}
			var axis_length := head.distance_to(tail) * 0.15
			if not is_finite(axis_length) or axis_length == 0:
				root.free()
				return {"error": "Uzel %d: délku kloubu nelze zobrazit v číselné přesnosti náhledu." % node_index, "report": report}
			var axis_x := head + _display_axis(frame.basis.x) * axis_length
			var axis_y := head + _display_axis(frame.basis.y) * axis_length
			var axis_z := head + _display_axis(frame.basis.z) * axis_length
			if not axis_x.is_finite() or not axis_y.is_finite() or not axis_z.is_finite():
				root.free()
				return {"error": "Uzel %d: osy rámce překračují číselný rozsah náhledu." % node_index, "report": report}
			_append_joint_line(joint_vertices, joint_colors, head, tail, Color(0.1, 0.9, 1.0))
			_append_joint_line(joint_vertices, joint_colors, head, axis_x, Color.RED)
			_append_joint_line(joint_vertices, joint_colors, head, axis_y, Color.GREEN)
			_append_joint_line(joint_vertices, joint_colors, head, axis_z, Color.BLUE)
			joint_count += 1
		if data.has("mesh"):
			var mesh: Dictionary = manifest.meshes[int(data.mesh)]
			for primitive in mesh.primitives:
				var built := _primitive(primitive, manifest, chunks, bytes, MAX_VERTICES - vertex_total, MAX_INDICES - triangle_total * 3, texture_cache, diagnostic and report.status == "unsupported")
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
	if joint_count > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = joint_vertices
		arrays[Mesh.ARRAY_COLOR] = joint_colors
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		material.no_depth_test = true
		mesh.surface_set_material(0, material)
		var joint_lines := MeshInstance3D.new()
		joint_lines.name = "ADMJointDisplay"
		joint_lines.mesh = mesh
		joint_lines.visible = false
		root.add_child(joint_lines)
		warnings.append("Rámce kloubů zobrazují pouze autorská display data v klidové póze, nikoli skinning nebo animaci.")
		warnings.append("ADM_joint_display_v1 je implementováno pouze částečně: úplná validace a zachování při importu/exportu chybí; výpočty používají přesnost Godotu.")
	report.runtimeStatus = "unsupported"
	report.runtimeLimitations = warnings
	report.preview = {
		"status": "diagnostic_only", "meshPrimitives": mesh_count,
		"vertices": vertex_total, "triangles": triangle_total,
		"boundsMin": [bounds.position.x, bounds.position.y, bounds.position.z],
		"boundsMax": [bounds.end.x, bounds.end.y, bounds.end.z],
		"diagnosticOverride": diagnostic and report.status == "unsupported",
		"jointDisplay": {"status": "available" if joint_count > 0 else "unavailable", "count": joint_count, "visible": false, "mode": "authored_rest_pose_only"},
		"limitations": warnings, "materials": material_info
	}
	return {"root": root, "bounds": bounds, "report": report}


static func _append_joint_line(vertices: PackedVector3Array, colors: PackedColorArray, start: Vector3, end: Vector3, color: Color) -> void:
	vertices.append(start)
	vertices.append(end)
	colors.append(color)
	colors.append(color)


static func _display_axis(axis: Vector3) -> Vector3:
	var largest := maxf(absf(axis.x), maxf(absf(axis.y), absf(axis.z)))
	return (axis / largest).normalized() if largest > 0 else Vector3.ZERO


static func _joint_displays(manifest: Dictionary) -> Dictionary:
	var result := {}
	var used: bool = manifest.get("extensionsUsed", []).has(JOINT_DISPLAY_EXTENSION)
	var required: bool = manifest.get("extensionsRequired", []).has(JOINT_DISPLAY_EXTENSION)
	for index in range(manifest.nodes.size()):
		var node: Variant = manifest.nodes[index]
		if typeof(node) != TYPE_DICTIONARY:
			return {"error": "Uzel %d není objekt." % index, "invalid": true}
		var extensions: Variant = node.get("extensions", {})
		if typeof(extensions) != TYPE_DICTIONARY:
			return {"error": "Uzel %d má neplatná rozšíření." % index, "invalid": true}
		if not extensions.has(JOINT_DISPLAY_EXTENSION):
			continue
		if not used:
			return {"error": "Uzel %d používá nedeklarované ADM_joint_display_v1." % index, "invalid": true}
		var parsed := _joint_display_frame(extensions[JOINT_DISPLAY_EXTENSION])
		if parsed.has("error"):
			return {"error": "Uzel %d: %s" % [index, parsed.error], "invalid": parsed.get("invalid", false)}
		result[index] = parsed
	if required:
		for skin in manifest.get("skins", []):
			if typeof(skin) != TYPE_DICTIONARY or typeof(skin.get("joints")) != TYPE_ARRAY:
				return {"error": "Skin nemá platné pole joints pro povinné ADM_joint_display_v1.", "invalid": true}
			for joint in skin.joints:
				if not _index(joint, manifest.nodes.size()) or not result.has(int(joint)):
					return {"error": "Skin odkazuje na kloub bez povinného ADM_joint_display_v1.", "invalid": true}
	return {"nodes": result}


static func _joint_display_frame(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY or value.size() != 3 or value.get("version") != "1.0.0" or not value.has("displayFrame") or not value.has("tail"):
		return {"error": "Neplatné členy nebo verze ADM_joint_display_v1.", "invalid": true}
	var m: Variant = value.displayFrame
	var tail: Variant = value.tail
	if not _numbers(m, 16) or not _numbers(tail, 3) or (tail[0] == 0 and tail[1] == 0 and tail[2] == 0):
		return {"error": "Neplatný displayFrame nebo nulový tail.", "invalid": true}
	if m[3] != 0 or m[7] != 0 or m[11] != 0 or m[15] != 1:
		return {"error": "displayFrame není afinní.", "invalid": true}
	var determinant: float = float(m[0]) * (float(m[5]) * float(m[10]) - float(m[9]) * float(m[6])) - float(m[4]) * (float(m[1]) * float(m[10]) - float(m[9]) * float(m[2])) + float(m[8]) * (float(m[1]) * float(m[6]) - float(m[5]) * float(m[2]))
	if not is_finite(determinant):
		return {"error": "Determinant displayFrame překračuje číselný rozsah náhledu."}
	if determinant == 0:
		var zero_column: bool = (m[0] == 0 and m[1] == 0 and m[2] == 0) or (m[4] == 0 and m[5] == 0 and m[6] == 0) or (m[8] == 0 and m[9] == 0 and m[10] == 0)
		return {"error": "displayFrame je singulární nebo mimo číselnou přesnost náhledu.", "invalid": zero_column}
	var transformed := _transform({"matrix": m})
	if transformed.has("error"):
		return transformed
	var frame: Transform3D = transformed.value
	var endpoint := Vector3(tail[0], tail[1], tail[2])
	var preview_determinant := frame.basis.determinant()
	if not frame.basis.is_finite() or not frame.origin.is_finite() or not endpoint.is_finite() or not is_finite(preview_determinant) or preview_determinant == 0 or endpoint == Vector3.ZERO:
		return {"error": "displayFrame nebo tail překračuje číselný rozsah náhledu."}
	return {"frame": frame, "tail": endpoint}


static func _primitive(primitive: Variant, manifest: Dictionary, chunks: Dictionary, bytes: PackedByteArray, vertex_limit: int, index_limit: int, texture_cache: Dictionary, partial_shader: bool = false) -> Dictionary:
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
	var output_material: Material = material
	var warnings: Array[String] = []
	var info := {"materialIndex": -1, "shaderId": "adm.pbr.metallic_roughness", "shaderVersion": "1.0.0", "shaderSupported": false, "shaderFallbackActive": true, "baseColorTexture": "absent", "emissiveTexture": "absent"}
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
		for field in ["metallicRoughnessTexture", "normalTexture", "occlusionTexture"]:
			if data.has(field):
				warnings.append("Materiál %d: %s zatím není vykreslen." % [int(primitive.material), field])
		var base_binding := {}
		var emission_binding := {}
		if data.has("baseColorTexture"):
			var binding := _base_texture(data.baseColorTexture, primitive.attributes, vertices.size(), manifest, chunks, bytes, texture_cache)
			if binding.has("error"):
				return binding
			if binding.has("warning"):
				info.baseColorTexture = "unsupported"
				warnings.append("Materiál %d: %s" % [int(primitive.material), binding.warning])
			else:
				base_binding = binding
				arrays[Mesh.ARRAY_TEX_UV] = binding.uv
				material.albedo_texture = binding.texture
				material.texture_repeat = binding.repeat
				material.texture_filter = binding.filter
				info.baseColorTexture = binding.source
				if binding.source == "fallback_png_jpeg":
					warnings.append("Materiál %d: základní textura používá PNG/JPEG fallback místo KTX2/DDS." % int(primitive.material))
		var emission: Variant = data.get("emissiveFactor", [0.0, 0.0, 0.0])
		if not _numbers(emission, 3) or emission[0] < 0 or emission[1] < 0 or emission[2] < 0:
			return {"error": "Neplatná emissiveFactor."}
		var emission_scale: float = maxf(float(emission[0]), maxf(float(emission[1]), float(emission[2])))
		if emission_scale > 0.0:
			material.emission_enabled = true
			material.emission = Color(emission[0] / emission_scale, emission[1] / emission_scale, emission[2] / emission_scale).linear_to_srgb()
			material.emission_energy_multiplier = emission_scale
			material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		if data.has("emissiveTexture"):
			var binding := _base_texture(data.emissiveTexture, primitive.attributes, vertices.size(), manifest, chunks, bytes, texture_cache)
			if binding.has("error"):
				return binding
			if binding.has("warning"):
				info.emissiveTexture = "unsupported"
				material.emission_enabled = false
				warnings.append("Materiál %d: emisní textura: %s" % [int(primitive.material), binding.warning])
			elif not base_binding.is_empty() and (base_binding.uv != binding.uv or base_binding.repeat != binding.repeat or base_binding.filter != binding.filter):
				info.emissiveTexture = "unsupported"
				material.emission_enabled = false
				warnings.append("Materiál %d: rozdílné UV nebo sampler emisní textury zatím nejsou podporovány." % int(primitive.material))
			else:
				emission_binding = binding
				arrays[Mesh.ARRAY_TEX_UV] = binding.uv
				material.texture_repeat = binding.repeat
				material.texture_filter = binding.filter
				material.emission_texture = binding.texture
				info.emissiveTexture = binding.source
				if binding.source == "fallback_png_jpeg":
					warnings.append("Materiál %d: emisní textura používá PNG/JPEG fallback místo KTX2/DDS." % int(primitive.material))
		if partial_shader:
			var detail := _detail_material(data, shader, primitive.attributes, vertices.size(), manifest, chunks, bytes, texture_cache, base_binding, emission_binding)
			if detail.has("error"):
				return detail
			if detail.has("warning"):
				warnings.append("Materiál %d: %s" % [int(primitive.material), detail.warning])
			if detail.has("material"):
				output_material = detail.material
				arrays[Mesh.ARRAY_COLOR] = detail.colors
				arrays[Mesh.ARRAY_TEX_UV] = detail.uv
				info.shaderFallbackActive = false
				info.shaderRendering = "partial_diagnostic"
				info.color1RTexture = detail.source
				info.color1RRoughnessTexture = detail.roughness_source
				warnings.erase("Shader %s@%s není podporován; používá se neúplný PBR fallback." % [shader.id, shader.version])
				warnings.append("Materiál %d: diagnostická částečná vrstva COLOR_1.R nenahrazuje úplný shader ani PBR fallback; normal mapy, metalické mapy a ostatní kanály nejsou vykresleny." % int(primitive.material))
	else:
		material.roughness = 1.0
		material.metallic = 1.0
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	array_mesh.surface_set_material(0, output_material)
	return {"mesh": array_mesh, "vertices": vertices, "triangles": indices.size() / 3, "warnings": warnings, "material_info": info}


static func _detail_material(data: Dictionary, shader: Dictionary, attributes: Dictionary, vertex_count: int, manifest: Dictionary, chunks: Dictionary, bytes: PackedByteArray, cache: Dictionary, base: Dictionary, emission: Dictionary) -> Dictionary:
	if shader.id != "adm.pbr.metallic_roughness" or shader.version != "2.1.0":
		return {}
	var parameters: Variant = data.get("shaderParameters", {})
	if typeof(parameters) != TYPE_DICTIONARY:
		return {"error": "shaderParameters musí být objekt."}
	if not parameters.has("color1_r_texture") or parameters.color1_r_texture == null:
		return {}
	if not manifest.get("extensionsUsed", []).has("ADM_vertex_control_v1") or not manifest.get("extensionsRequired", []).has("ADM_vertex_control_v1"):
		return {"error": "COLOR_1 vyžaduje povinné rozšíření ADM_vertex_control_v1."}
	if data.get("alphaMode", "OPAQUE") != "OPAQUE":
		return {"warning": "Diagnostická textura COLOR_1.R zatím podporuje pouze neprůhledné materiály."}
	if data.has("baseColorTexture") and base.is_empty() or data.has("emissiveTexture") and emission.is_empty():
		return {"warning": "Diagnostická textura COLOR_1.R vyžaduje dostupné základní a emisní textury."}
	var detail := _base_texture(parameters.color1_r_texture, attributes, vertex_count, manifest, chunks, bytes, cache)
	if detail.has("error"):
		return detail
	if detail.has("warning"):
		return detail
	if not detail.repeat or detail.filter != BaseMaterial3D.TEXTURE_FILTER_LINEAR:
		return {"warning": "Diagnostická textura COLOR_1.R vyžaduje sampler LINEAR/REPEAT."}
	for binding in [base, emission]:
		if not binding.is_empty() and (binding.uv != detail.uv or not binding.repeat or binding.filter != detail.filter):
			return {"warning": "Diagnostická textura COLOR_1.R vyžaduje stejné UV a LINEAR/REPEAT u základní a emisní textury."}
	var mask := _detail_mask(attributes, vertex_count, manifest, chunks, bytes)
	if mask.has("error"):
		return mask
	var color: Variant = parameters.get("color1_r_color", [0.72, 0.72, 0.72])
	if not _numbers(color, 3):
		return {"error": "Neplatná barva COLOR_1.R."}
	for component in color:
		if component < 0 or component > 1:
			return {"error": "Barva COLOR_1.R je mimo rozsah."}
	for field in ["color1_r_strength", "color1_r_metallic", "color1_r_roughness"]:
		var value: Variant = parameters.get(field, {"color1_r_strength": 1.0, "color1_r_metallic": 0.0, "color1_r_roughness": 0.6}[field])
		if (typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT) or not is_finite(float(value)) or value < 0 or value > 1:
			return {"error": "Neplatný parametr %s." % field}
	var roughness := {}
	if parameters.has("color1_r_roughness_texture") and parameters.color1_r_roughness_texture != null:
		roughness = _base_texture(parameters.color1_r_roughness_texture, attributes, vertex_count, manifest, chunks, bytes, cache)
		if roughness.has("error") or roughness.has("warning"):
			return roughness
		if roughness.uv != detail.uv or not roughness.repeat or roughness.filter != detail.filter:
			return {"warning": "Diagnostická textura drsnosti COLOR_1.R vyžaduje stejný UV a sampler jako detail."}
	var channel: Variant = parameters.get("color1_r_roughness_channel", 0.0)
	var invert: Variant = parameters.get("color1_r_roughness_invert", false)
	if (typeof(channel) != TYPE_INT and typeof(channel) != TYPE_FLOAT) or not is_finite(float(channel)) or channel < 0 or channel > 3 or typeof(invert) != TYPE_BOOL:
		return {"error": "Neplatný kanál nebo inverze textury drsnosti COLOR_1.R."}
	var result := ShaderMaterial.new()
	result.shader = DETAIL_SHADER
	result.set_shader_parameter("detail_texture", detail.texture)
	result.set_shader_parameter("detail_factor", Vector3(color[0], color[1], color[2]))
	result.set_shader_parameter("detail_strength", float(parameters.get("color1_r_strength", 1.0)))
	result.set_shader_parameter("detail_metallic", float(parameters.get("color1_r_metallic", 0.0)))
	result.set_shader_parameter("detail_roughness", float(parameters.get("color1_r_roughness", 0.6)))
	result.set_shader_parameter("base_metallic", float(data.get("metallicFactor", 1.0)))
	result.set_shader_parameter("base_roughness", float(data.get("roughnessFactor", 1.0)))
	var base_color: Array = data.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
	result.set_shader_parameter("base_factor", Vector4(base_color[0], base_color[1], base_color[2], base_color[3]))
	var emission_factor: Array = data.get("emissiveFactor", [0.0, 0.0, 0.0])
	result.set_shader_parameter("emissive_factor", Vector3(emission_factor[0], emission_factor[1], emission_factor[2]))
	for item in [{"binding": base, "name": "base"}, {"binding": emission, "name": "emissive"}, {"binding": roughness, "name": "roughness"}]:
		if not item.binding.is_empty():
			result.set_shader_parameter("has_%s_texture" % item.name, true)
			result.set_shader_parameter("%s_texture" % item.name, item.binding.texture)
	result.set_shader_parameter("roughness_channel", int(floor(float(channel) + 0.5)))
	result.set_shader_parameter("roughness_invert", invert)
	return {"material": result, "colors": mask.colors, "uv": detail.uv, "source": detail.source, "roughness_source": roughness.get("source", "absent")}


static func _detail_mask(attributes: Dictionary, vertex_count: int, manifest: Dictionary, chunks: Dictionary, bytes: PackedByteArray) -> Dictionary:
	var colors := PackedColorArray()
	if not attributes.has("COLOR_1"):
		colors.resize(vertex_count)
		colors.fill(Color(0, 0, 0, 0))
		return {"colors": colors}
	var input := _accessor(attributes.COLOR_1, "COLOR", "VEC4", manifest, chunks, bytes, vertex_count)
	if input.has("error"):
		return input
	if int(input.accessor.count) != vertex_count:
		return {"error": "Počet hodnot COLOR_1 neodpovídá počtu vrcholů."}
	var is_u8: bool = input.accessor.componentType == "U8"
	for index in range(vertex_count):
		var at: int = input.offset + index * (4 if is_u8 else 16)
		var values := []
		for component in range(4):
			var value: float = float(bytes[at + component]) / 255.0 if is_u8 else bytes.decode_float(at + component * 4)
			if not is_finite(value) or value < 0 or value > 1:
				return {"error": "COLOR_1 obsahuje neplatnou hodnotu."}
			values.append(value)
		colors.append(Color(values[0], values[1], values[2], values[3]))
	return {"colors": colors}


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
	var source := "png_jpeg"
	var source_dimensions := Vector2i.ZERO
	if image_data.mimeType == "image/ktx2" or image_data.mimeType == "image/vnd-ms.dds":
		if not texture.has("fallbackSource") or not _index(texture.fallbackSource, images.size()):
			return {"error": "KTX2/DDS textura vyžaduje platný PNG/JPEG fallbackSource."}
		var gpu_data := _image_bytes(image_data, manifest, chunks, bytes, true)
		if gpu_data.has("error") or gpu_data.has("warning"):
			return gpu_data
		source_dimensions = _image_dimensions(gpu_data.bytes, image_data.mimeType)
		if source_dimensions.x <= 0 or source_dimensions.y <= 0:
			return {"error": "KTX2/DDS obrázek nemá platnou hlavičku."}
		image_index = int(texture.fallbackSource)
		image_data = images[image_index]
		if typeof(image_data) != TYPE_DICTIONARY or not ["image/png", "image/jpeg"].has(image_data.get("mimeType")):
			return {"error": "KTX2/DDS fallback musí být PNG nebo JPEG."}
		source = "fallback_png_jpeg"
	elif texture.has("fallbackSource"):
		return {"error": "PNG/JPEG textura nesmí mít fallbackSource."}
	if image_data.mimeType != "image/png" and image_data.mimeType != "image/jpeg":
		return {"error": "Nepovolený mimeType obrázku."}
	var image_bytes := _image_bytes(image_data, manifest, chunks, bytes)
	if image_bytes.has("error") or image_bytes.has("warning"):
		return image_bytes
	var encoded: PackedByteArray = image_bytes.bytes
	var dimensions := _image_dimensions(encoded, image_data.mimeType)
	if dimensions.x <= 0 or dimensions.y <= 0:
		return {"error": "Obrázek nemá platnou hlavičku odpovídající mimeType."}
	if source_dimensions != Vector2i.ZERO and source_dimensions != dimensions:
		return {"error": "KTX2/DDS a PNG/JPEG fallback mají rozdílné rozměry."}
	if dimensions.x > MAX_IMAGE_DIMENSION or dimensions.y > MAX_IMAGE_DIMENSION or dimensions.x * dimensions.y > MAX_IMAGE_PIXELS:
		return {"warning": "Obrázek překračuje limit velikosti náhledu."}
	var uv := PackedVector2Array()
	for index in range(vertex_count):
		var offset: int = uv_accessor.offset + index * 8
		uv.append(Vector2(bytes.decode_float(offset), bytes.decode_float(offset + 4)))
	if not cache.has(image_index):
		var image := Image.new()
		var status: Error = image.load_png_from_buffer(encoded) if image_data.mimeType == "image/png" else image.load_jpg_from_buffer(encoded)
		if status != OK or image.is_empty() or image.get_width() != dimensions.x or image.get_height() != dimensions.y:
			return {"error": "Obrázek nelze dekódovat: %s." % error_string(status)}
		cache[image_index] = ImageTexture.create_from_image(image)
	return {"uv": uv, "texture": cache[image_index], "repeat": wrap_s == "REPEAT",
		"filter": BaseMaterial3D.TEXTURE_FILTER_NEAREST if min_filter == "NEAREST" else BaseMaterial3D.TEXTURE_FILTER_LINEAR, "source": source}


static func _image_bytes(image_data: Dictionary, manifest: Dictionary, chunks: Dictionary, bytes: PackedByteArray, header_only: bool = false) -> Dictionary:
	if not image_data.has("bufferView") or not _index(image_data.bufferView, manifest.bufferViews.size()):
		return {"error": "Obrázek odkazuje na neexistující bufferView."}
	var view: Dictionary = manifest.bufferViews[int(image_data.bufferView)]
	var chunk: Dictionary = chunks[int(view.chunkId)]
	if chunk.type != "IMAG":
		return {"error": "Obrázek musí odkazovat na IMAG chunk."}
	if chunk.codec != 0:
		return {"warning": "Obrázek používá nepodporovanou kompresi chunku."}
	var start: int = chunk.offset + int(view.byteOffset)
	if start < 0 or start > bytes.size() or int(view.byteLength) > bytes.size() - start:
		return {"error": "Data obrázku jsou mimo rozsah souboru."}
	var length: int = mini(int(view.byteLength), 148) if header_only else int(view.byteLength)
	return {"bytes": bytes.slice(start, start + length)}


static func _image_dimensions(data: PackedByteArray, mime: String) -> Vector2i:
	if mime == "image/vnd-ms.dds":
		if data.size() < 148 or data.slice(0, 4).get_string_from_ascii() != "DDS " or data.decode_u32(4) != 124 or data.slice(84, 88).get_string_from_ascii() != "DX10":
			return Vector2i.ZERO
		return Vector2i(data.decode_u32(16), data.decode_u32(12))
	if mime == "image/ktx2":
		if data.size() < 80 or data.slice(0, 12) != PackedByteArray([171, 75, 84, 88, 32, 50, 48, 187, 13, 10, 26, 10]):
			return Vector2i.ZERO
		return Vector2i(data.decode_u32(20), data.decode_u32(24))
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
	var format_ok: bool = (component == "INDEX" and ["U16", "U32"].has(accessor.componentType) and not accessor.get("normalized", false)) or (component == "COLOR" and ((accessor.componentType == "U8" and accessor.get("normalized", false)) or (accessor.componentType == "F32" and not accessor.get("normalized", false)))) or (component != "INDEX" and component != "COLOR" and accessor.componentType == component and not accessor.get("normalized", false))
	if accessor.type != shape or not format_ok:
		return {"error": "Nepodporovaný nebo neplatný formát accessor %d." % int(index)}
	if not Validator._is_uint(accessor.count) or int(accessor.count) > limit:
		return {"error": "Geometrie překračuje limit náhledu."}
	var view: Dictionary = manifest.bufferViews[int(accessor.bufferView)]
	var chunk: Dictionary = chunks[int(view.chunkId)]
	if chunk.codec != 0:
		return {"error": "Geometrie vyžaduje nepodporovanou kompresi."}
	var local_offset: int = int(accessor.get("byteOffset", 0))
	var length: int = int(accessor.count) * int(Validator.COMPONENT_COUNTS[shape]) * int(Validator.COMPONENT_SIZES[accessor.componentType])
	var offset: int = chunk.offset + int(view.byteOffset) + local_offset
	if local_offset < 0 or local_offset > int(view.byteLength) or length > int(view.byteLength) - local_offset or offset < 0 or offset > bytes.size() or length > bytes.size() - offset:
		return {"error": "Accessor přesahuje bufferView nebo soubor."}
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
