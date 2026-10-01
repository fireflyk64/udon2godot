// Port of "harry_t/text_alpha" (MS-VRCSA-Billiards, Shaders/TextAlpha.shader): the texture's
// alpha in a colour, added onto what is behind it.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform sampler2D _MainTex : hint_default_white, filter_linear_mipmap;
uniform vec4 _Color : source_color = vec4(1.0);

void fragment() {
	ALBEDO = _Color.rgb * texture(_MainTex, UV).a;
}
