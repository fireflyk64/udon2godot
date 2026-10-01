## Writes where every converted canvas of the world draws its UI nodes, as JSON
## (`--dump-out <file>`, default user://canvas_dump.json) for tools/unity_ui_reference.py --compare.
## The description itself is unidot's (addons/unidot_importer/test/ui_dump.gd).
## `--dump-wait N` waits N frames first; with the runner's `--static` the scripts do not run, so
## the dump shows the imported layout as the Unity files describe it.
extends RefCounted


func run(r) -> bool:
	await r.wait(int(r._args.get("dump-wait", 10)))
	var dumper = load("res://addons/unidot_importer/test/ui_dump.gd")
	var out: Dictionary = dumper.dump(r._scene)
	var path: String = str(r._args.get("dump-out", "user://canvas_dump.json"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " "))
	f.close()
	var total: int = 0
	for c in out["canvases"]:
		total += c["nodes"].size()
	print("[canvas_dump] %d canvases, %d nodes -> %s" % [out["canvases"].size(), total, path])
	r.check(out["canvases"].size() > 0, "the world has converted canvases")
	return true
