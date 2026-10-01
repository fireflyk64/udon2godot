// Port of "harry_t/twoframe" (MS-VRCSA-Billiards, Shaders/TwoFrame.shader): a texture of two
// frames side by side, shown in turn (_Speed switches per 20 seconds), added onto what is
// behind it.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap;
uniform float _Speed = 20.0;

void fragment() {
	// Unity's _Time.x is the time / 20
	vec2 uv = UV * vec2(0.5, 1.0) + vec2(0.5, 0.0) * mod(floor(TIME / 20.0 * _Speed), 2.0);
	ALBEDO = texture(_MainTex, uv).rgb;
}
