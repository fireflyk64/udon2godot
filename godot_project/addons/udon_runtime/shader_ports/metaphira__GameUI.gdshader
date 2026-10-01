// Port of "metaphira/GameUI" (MS-VRCSA-Billiards, Shaders/GameUI.shader): a quad drawn on the
// screen, not in the world (the desktop key hints). Its vertices are placed in clip space from
// the top-right corner: _Trf.xy scales the mesh (x, z), _Trf.zw moves it; always on top.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, skip_vertex_transform;

uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap;
uniform vec4 _Trf = vec4(0.0);

void vertex() {
	float ratio = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	// Unity's object space: the importer mirrors x
	vec2 scalepos = vec2(-VERTEX.x, VERTEX.z) * _Trf.xy;
	scalepos.y *= ratio;
	vec2 location = vec2(1.0) + scalepos + _Trf.zw;
	POSITION = vec4(-location.x, location.y, 1.0, 1.0);
}

void fragment() {
	vec4 col = texture(_MainTex, UV);
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
