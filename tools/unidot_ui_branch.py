#!/usr/bin/env python3
"""Builds the branch `ui-canvas` of the unidot fork: upstream main (origin/main) plus only the
Unity UI work (RectTransform / canvas conversion and its run-time modules), as three commits,
for upstreaming without the Udon integration, the shader and the particle work of the fork.

    tools/unidot_ui_branch.py [fork checkout] [worktree dir]
        (defaults: refs/unidot_importer, a temporary directory that is removed again)

The fork's checked-out branch (`udon-integration`) is the source of every file: UI files are
copied, and of the importer's core files only the hunks that the UI needs are applied. The
branch is rebuilt from scratch each time (an existing `ui-canvas` is replaced). Check it with
    UNIDOT=<worktree dir> REIMPORT=1 scripts/test_ui.sh /tmp/udon2godot_worlds/ui_branch
(the command-line import driver `headless/` is borrowed from the fork by the test)."""
import os, re, shutil, subprocess, sys

import tempfile
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fork = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "refs", "unidot_importer"))
keep_tree = len(sys.argv) > 2
tree = os.path.abspath(sys.argv[2]) if keep_tree else os.path.join(tempfile.mkdtemp(prefix="unidot_ui_"), "unidot_ui")
TRAILER = "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01JgdvPUU3RuqyocC9zG9jY9"

def git(*args, cwd=fork, check=True, inp=None):
    r = subprocess.run(["git"] + list(args), cwd=cwd, input=inp, capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit("git %s failed:\n%s%s" % (" ".join(args), r.stdout, r.stderr))
    return r.stdout

# a fresh worktree on a fresh branch from upstream
# (a worktree that still has the branch checked out would keep it from being replaced)
current = ""
for line in git("worktree", "list", "--porcelain").splitlines():
    if line.startswith("worktree "):
        current = line[len("worktree "):]
    elif line == "branch refs/heads/ui-canvas" and os.path.abspath(current) != fork:
        git("worktree", "remove", "--force", current, check=False)
git("worktree", "prune")
git("branch", "-D", "ui-canvas", check=False)
git("worktree", "add", "-b", "ui-canvas", tree, "origin/main")

def hunks(path):
    d = git("diff", "origin/main..HEAD", "--", path)
    head, *rest = re.split(r"\n(?=@@ )", d)
    return head, rest

def apply(path, keep, edit=None):
    """Apply the fork's hunks of `path` that `keep(hunk)` accepts (after `edit(hunk)`)."""
    head, hs = hunks(path)
    chosen = []
    for h in hs:
        if edit:
            h = edit(h)
        if h and keep(h):
            chosen.append(h.rstrip("\n"))
    patch = head + "\n" + "\n".join(chosen) + "\n"
    r = subprocess.run(["git", "apply", "--recount", "--whitespace=nowarn", "-"], cwd=tree, input=patch, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("applying %s failed:\n%s" % (path, r.stderr))
    return len(chosen), len(hs)

def added(h):
    return "\n".join(l for l in h.split("\n")[1:] if l.startswith("+"))

# ---- 1. scene nodes may be any Node; plugin hooks for GameObject nodes and component overrides
NOT_UI = ("shaderlab", "shader_info", "shader_ref", "ParticleSystem", "mat_slots", "bias", "msaa", "get_godot_extension", "source_mesh",
          "An inactive GameObject shows nothing")   # (hiding inactive objects is a fix of its own)
def oa_edit(h):
    lines = h.split("\n")
    # mixed hunks: the preloads and the type table
    lines = [l for l in lines if not (l.startswith("+") and ("shaderlab" in l or "UnidotParticleSystem" in l))]
    lines = [(" " + l[1:]) if (l.startswith("-") and "ParticleSystem" in l) else l for l in lines]
    return "\n".join(lines)
def oa_keep(h):
    a = added(h)
    if not a.strip():
        return False
    return not any(k in a for k in NOT_UI)
n = apply("object_adapter.gd", oa_keep, oa_edit)
print("object_adapter.gd: %d of %d hunks" % n)
# signature changes that sat in hunks which are otherwise not UI (next to the particle system)
p = os.path.join(tree, "object_adapter.gd")
s = open(p).read()
s, count = re.subn(r"(func create_(?:cloth_)?godot_node\((?:x?state): RefCounted, new_parent: )Node3D\b", r"\1Node", s)
open(p, "w").write(s)
print("object_adapter.gd: %d more node signatures" % count)
# the constraint classes (a plugin hook for Unity's Animations constraints) are not UI: they share
# a hunk with the canvas group, so they are taken out of the file again
s = open(p).read()
start, end = s.find("class UnidotConstraint:"), s.find("class UnidotMonoBehaviour:")
if start >= 0:
    assert end > start
    s = s[:start] + s[end:]
    s, count = re.subn(r'(?m)^\t"(\w+Constraint)": Unidot\1,$', r'\t# "\1": Unidot\1,', s)
    assert count == 6, count
    open(p, "w").write(s)
    print("object_adapter.gd: constraint classes left out")
print("scene_node_state.gd: %d of %d hunks" % apply("scene_node_state.gd", lambda h: True))
# (not UI either: skybox materials, the order of a scene's roots)
print("convert_scene.gd: %d of %d hunks" % apply("convert_scene.gd", lambda h: "sky_material" not in added(h) and "scene_roots" not in added(h)))

# the UI plugin is loaded by the asset database (the fork also has a generic extra-plugin setting,
# which is not part of this branch)
p = os.path.join(tree, "asset_database.gd")
s = open(p).read()
def rep(old, new):
    global s
    assert old in s, old
    s = s.replace(old, new, 1)
rep('const vrm_integration_class := preload("./vrm_integration.gd")\n', 'const vrm_integration_class := preload("./vrm_integration.gd")\nconst ui_integration_class := preload("./ui_integration.gd")\n')
rep('@export var vrm_spring_bones: bool = true\n', '@export var vrm_spring_bones: bool = true\n## Convert Unity UI (Canvas, RectTransform, uGUI and TextMeshPro components) to Controls.\n@export var convert_ui: bool = true\n')
rep('var vrm_integration_plugin\n', 'var vrm_integration_plugin\nvar ui_integration_plugin\n')
rep('''func get_enabled_plugins() -> Array[RefCounted]:
	if vrm_spring_bones:
		if vrm_integration_plugin == null:
			vrm_integration_plugin = vrm_integration_class.new()
		return [vrm_integration_plugin]
	return []
''', '''func get_enabled_plugins() -> Array[RefCounted]:
	var out: Array[RefCounted] = []
	if convert_ui:
		if ui_integration_plugin == null:
			ui_integration_plugin = ui_integration_class.new()
			ui_integration_plugin.set_database(self)
		out.append(ui_integration_plugin)
	if vrm_spring_bones:
		if vrm_integration_plugin == null:
			vrm_integration_plugin = vrm_integration_class.new()
		out.append(vrm_integration_plugin)
	return out
''')
open(p, "w").write(s)

# the UI files: the plugin, and everything the fork added or changed under runtime/ and test/
UI_FILES = ["ui_integration.gd"] + [f for f in git("diff", "--name-only", "origin/main..HEAD", "--", "runtime", "test").split() if f]
for f in UI_FILES:
    src, dst = os.path.join(fork, f), os.path.join(tree, f)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.isdir(src):
        shutil.copytree(src, dst, dirs_exist_ok=True)
    else:
        shutil.copy2(src, dst)

def commit(paths, message):
    git("add", *paths, cwd=tree)
    git("commit", "-q", "-m", message + "\n\n" + TRAILER, cwd=tree)

# commit 1: the YAML fix stands on its own
print("yaml_parser.gd: %d of %d hunks" % apply("yaml_parser.gd", lambda h: True))
commit(["yaml_parser.gd"], "yaml_parser: single-quoted scalars keep neither their closing quote nor lose doubled quotes\n\n'>>' was read as >>' and '' inside a quoted string was dropped instead of standing for one quote.")
commit(["object_adapter.gd", "scene_node_state.gd", "convert_scene.gd"],
       "Scene nodes may be any Node: plugin hooks for GameObject nodes and component overrides\n\n"
       "A GameObject is not always a Node3D (a RectTransform becomes a Control), so the node-building\n"
       "functions take and return Node. Plugins may build the node of a GameObject\n"
       "(create_gameobject_node), take the property overrides of a MonoBehaviour on a prefab instance\n"
       "(convert_monobehaviour_properties; the virtual object carries the modified object's file id),\n"
       "and RectTransform overrides are converted through the UI plugin. Canvas, CanvasRenderer and\n"
       "CanvasGroup are known component types.")
commit(["asset_database.gd"] + UI_FILES,
       "Unity UI: canvases, RectTransform, layout, text, graphics, sprites, selectables, scroll rects\n\n"
       "ui_integration.gd (an importer plugin, on by default: AssetDatabase.convert_ui) converts\n"
       "RectTransform GameObjects to Controls and Canvases to world canvases (SubViewport + quad) or\n"
       "CanvasLayers. The run-time modules hold Unity's rules and are used by the importer and at run\n"
       "time alike: rect_transform.gd (anchors, pivots, offsets, world matrices, controls that leave\n"
       "their canvas plane), layout_group.gd (LayoutRebuilder, layout groups, fitters), ui_text.gd\n"
       "(rich text, styles, auto-size, overflow), ui_graphic.gd (colour x CanvasRenderer colour x\n"
       "enabled), ui_sprite.gd (sliced, tiled, filled sprites; stand-ins for the built-in sprites),\n"
       "selectable.gd (colour tint, Toggle, Slider, Scrollbar), scroll_rect.gd (ScrollRect).\n"
       "test/: unit tests (rect_transform_test.gd), a dump of what a scene draws (ui_dump.gd) and a\n"
       "rendering check (ui_shots.gd).")
print(git("log", "--oneline", "-4", cwd=tree))
print(git("diff", "--stat", "origin/main..ui-canvas", cwd=tree).splitlines()[-1])
if not keep_tree:
    git("worktree", "remove", "--force", tree)
    print("branch ui-canvas built in %s (no worktree kept; pass a directory to keep one)" % fork)
