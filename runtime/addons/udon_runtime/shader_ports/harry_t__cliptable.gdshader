// Port of "harry_t/cliptable" (MS-VRCSA-Billiards, Shaders/CueGuideline.shader): the aiming
// guide line, added onto what is behind it and cut off at the edges of the table. The script
// hands over the table's world-to-local matrix (_BaseTransform, Unity space) and the half
// extents of the playing surface (_Dims).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 _Dims = vec4(0.0);
uniform mat4 _BaseTransform = mat4(1.0);
uniform vec4 _Colour : source_color = vec4(1.0);

varying vec3 table_pos;

void vertex() {
	// the matrix is in Unity's world space: Godot's world mirrored in x
	vec4 world = MODEL_MATRIX * vec4(VERTEX, 1.0);
	world.x = -world.x;
	table_pos = (_BaseTransform * world).xyz;
}

void fragment() {
	if (abs(table_pos.x) > _Dims.x || abs(table_pos.z) > _Dims.y) {
		discard;
	}
	vec4 col = texture(_MainTex, UV * _MainTex_ST.xy + _MainTex_ST.zw) * _Colour;
	ALBEDO = col.rgb;
}
