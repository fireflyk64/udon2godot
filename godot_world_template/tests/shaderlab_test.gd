## Unit checks for unidot_importer/shaderlab.gd (run inside an imported world project):
##   godot --headless --path <project> -s tests/shaderlab_test.gd
extends SceneTree

const shaderlab := preload("res://addons/unidot_importer/shaderlab.gd")

var _fails: int = 0
var _checks: int = 0

func check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL " + what)

func _init() -> void:
	var t := """
Shader "metaphira/Ball Shadow"
{
   Properties
   {
      _MainTex("Texture", 2D) = "white" {}
      _Floor("Surface Height (World Space)", Float) = 0.0
      [HDR] _Color("Main Color", Color) = (1,1,1,1)
   }
   SubShader
   {
      Tags { "Queue" = "AlphaTest+3" "DisableBatching" = "true" }
      ZWrite Off
      Cull Off
      Pass
      {
         Blend SrcAlpha OneMinusSrcAlpha
         CGPROGRAM
         #pragma vertex vert
         #pragma fragment frag
         ENDCG
      }
   }
}
"""
	var i: Dictionary = shaderlab.parse(t)
	check(i["name"] == "metaphira/Ball Shadow", "name: " + str(i["name"]))
	check(i["properties"].has("_MainTex") and i["properties"]["_MainTex"]["type"] == "2D", "property _MainTex 2D")
	check(i["properties"].has("_Color") and i["properties"]["_Color"]["type"] == "Color", "attribute-prefixed property")
	check(i["tags"].get("Queue") == "AlphaTest+3", "queue tag: " + str(i["tags"]))
	check(i["blend"] == ["SrcAlpha", "OneMinusSrcAlpha"], "blend: " + str(i["blend"]))
	check(i["zwrite"] == "Off" and i["cull"] == "Off", "zwrite/cull")
	check(i["lit"] == false, "vert/frag without lighting is unlit")
	var m := StandardMaterial3D.new()
	var applied: String = shaderlab.apply_render_state(m, i, {}, {})
	check(m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and m.blend_mode == BaseMaterial3D.BLEND_MODE_MIX, "alpha blend applied: " + applied)
	check(m.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED, "zwrite off → depth draw disabled")
	check(m.cull_mode == BaseMaterial3D.CULL_DISABLED, "cull off")
	check(m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "unshaded")
	check(m.render_priority == 3, "render priority from queue offset: " + str(m.render_priority))

	var surf := "Shader \"X/Surf\" { SubShader { Tags { \"RenderType\"=\"Opaque\" } CGPROGRAM\n#pragma surface surf Standard fullforwardshadows\nENDCG } }"
	i = shaderlab.parse(surf)
	check(i["lit"] == true and i["blend"].is_empty(), "surface shader is lit and opaque")
	m = StandardMaterial3D.new()
	shaderlab.apply_render_state(m, i, {}, {})
	check(m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and m.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL, "opaque lit untouched")

	var add := "Shader \"X/Add\" { SubShader { Tags { \"Queue\" = \"Transparent+13\" } ZWrite [_ZWrite] Cull [_Cull] Pass { Blend [_SrcBlend] [_DstBlend] // comment Blend One One\n CGPROGRAM ENDCG } } }"
	i = shaderlab.parse(add)
	check(i["blend"] == ["[_SrcBlend]", "[_DstBlend]"], "material-driven blend: " + str(i["blend"]))
	m = StandardMaterial3D.new()
	shaderlab.apply_render_state(m, i, {"_SrcBlend": 1.0, "_DstBlend": 1.0, "_ZWrite": 0.0, "_Cull": 0.0}, {})
	check(m.blend_mode == BaseMaterial3D.BLEND_MODE_ADD and m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "One One → additive")
	check(m.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED and m.cull_mode == BaseMaterial3D.CULL_DISABLED, "[_ZWrite]/[_Cull] resolved from floats")
	check(m.render_priority == 13, "priority 13")

	var sky := "Shader \"Custom/Sky6\" { Properties { _FrontTex (\"Front\", 2D) = \"grey\" {} _BackTex (\"Back\", 2D) = \"grey\" {} } SubShader { Tags { \"Queue\"=\"Background\" \"PreviewType\"=\"Skybox\" } Pass { } } }"
	i = shaderlab.parse(sky)
	check(i.get("sky", "") == "6 Sided", "custom skybox detected: " + str(i.get("sky")))
	check(shaderlab.sky_kind(shaderlab.builtin_info(106), {}, {}, {}) == "Procedural", "builtin 106 is Skybox/Procedural")
	check(shaderlab.sky_kind({}, {"_FrontTex": {}, "_BackTex": {}, "_UpTex": {}}, {}, {}) == "6 Sided", "unknown shader with 6 face textures")
	check(shaderlab.builtin_info(10752)["lit"] == false, "Unlit/Texture is unlit")
	check(shaderlab.port_file_name("metaphira/Ball Shadow") == "metaphira__Ball_Shadow.gdshader", "port file name")
	check(shaderlab.find_port("metaphira/Ball Shadow") != "", "ball shadow port installed: " + shaderlab.find_port("metaphira/Ball Shadow"))

	# equirect stitching: solid-colour faces land in the right part of the panorama
	var faces: Dictionary = {}
	var cols: Dictionary = {"+x": Color.RED, "-x": Color.GREEN, "+y": Color.BLUE, "-y": Color.YELLOW, "+z": Color.WHITE, "-z": Color.BLACK}
	for k in cols:
		var im := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		im.fill(cols[k])
		faces[k] = im
	var pano: Image = shaderlab.equirect_from_faces(faces, 64, 0.0, Color(1, 1, 1, 1))
	check(pano.get_pixel(32, 1).is_equal_approx(Color.BLUE), "top of panorama is +Y: " + str(pano.get_pixel(32, 1)))
	check(pano.get_pixel(32, 30).is_equal_approx(Color.YELLOW), "bottom of panorama is -Y: " + str(pano.get_pixel(32, 30)))
	check(pano.get_pixel(48, 16).is_equal_approx(Color.RED), "Godot -X (u=0.75) shows Unity +X (Left) after the mirror: " + str(pano.get_pixel(48, 16)))
	check(pano.get_pixel(16, 16).is_equal_approx(Color.GREEN), "Godot +X (u=0.25) shows Unity -X (Right): " + str(pano.get_pixel(16, 16)))
	check(pano.get_pixel(0, 16).is_equal_approx(Color.BLACK), "Godot -Z (u=0) is Unity -Z (Back): " + str(pano.get_pixel(0, 16)))
	check(pano.get_pixel(32, 16).is_equal_approx(Color.WHITE), "Godot +Z (u=0.5) is Unity +Z (Front): " + str(pano.get_pixel(32, 16)))
	print("[shaderlab_test] %d checks, %d failure(s)" % [_checks, _fails])
	quit(0 if _fails == 0 else 1)
