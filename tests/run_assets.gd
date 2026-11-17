extends SceneTree

const Validator = preload("res://scripts/adm_validator.gd")
const ASSET_DIR := "res://ADM"
const REPORT_PATH := "res://reports/uploaded-assets.json"
const EXPECTED := {
	"triangle.adm": "supported",
	"shader_layered.adm": "supported",
	"humanoid.adm": "unsupported",
}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := DirAccess.open(ASSET_DIR)
	if directory == null:
		push_error("Cannot open asset directory '%s': %s" % [ASSET_DIR, error_string(DirAccess.get_open_error())])
		quit(1)
		return
	var files := directory.get_files()
	files.sort()
	var results: Array = []
	var seen := {}
	var passed := true
	for file_name in files:
		var lower_name := file_name.to_lower()
		if not lower_name.ends_with(".adm") and not lower_name.ends_with(".adm_anim"):
			continue
		var inspected: Dictionary = Validator.inspect_path(ASSET_DIR.path_join(file_name))
		seen[file_name] = true
		var expected: String = EXPECTED.get(file_name, "")
		if not expected.is_empty() and inspected.status != expected:
			passed = false
		results.append({
			"source": file_name,
			"assetSha256": inspected.assetSha256,
			"status": inspected.status,
			"expectedSubsetStatus": expected if not expected.is_empty() else null,
			"runtimeStatus": inspected.runtimeStatus,
			"capabilities": inspected.capabilities,
			"diagnostics": inspected.diagnostics,
			"unsupported": inspected.unsupported,
			"deviations": inspected.deviations,
		})
	for name in EXPECTED:
		if not seen.has(name):
			push_error("Required regression asset is missing: %s" % name)
			passed = false
	if results.is_empty():
		push_error("No ADM assets found in %s." % ASSET_DIR)
		quit(1)
		return
	var report := {
		"reportType": "Uploaded ADM assets: validation subset",
		"specification": {"version": "ADM 1.0", "commit": Validator.SPEC_SHA, "url": Validator.SPEC_URL},
		"engineVersion": Engine.get_version_info().string,
		"assetProvenance": "User-supplied local files; upstream commit is not established.",
		"results": results,
		"limitations": [
			"Subset checks do not establish full ADM validity or conformance.",
			"Extension data is preserved, not interpreted; required extensions remain unsupported.",
			"Only a separate diagnostic static geometry preview with partial material and PNG/JPEG texture support exists; animation evaluation and IK are not implemented."
		],
	}
	var output_file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if output_file == null:
		push_error("Cannot write asset report: %s" % error_string(FileAccess.get_open_error()))
		quit(1)
		return
	output_file.store_string(JSON.stringify(report, "\t") + "\n")
	output_file.close()
	print("Asset report: %s (%d files)" % [ProjectSettings.globalize_path(REPORT_PATH), results.size()])
	quit(0 if passed else 1)
