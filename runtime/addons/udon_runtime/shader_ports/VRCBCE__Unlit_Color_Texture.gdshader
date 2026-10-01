// Port of "VRCBCE/Unlit Color+Texture" (vrcbce, Shaders/UnlitColorTexture.shader): the texture
// times a colour, unlit.
shader_type spatial;
render_mode unshaded;

uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 _Color : source_color = vec4(1.0);

void fragment() {
	vec4 col = texture(_MainTex, UV * _MainTex_ST.xy + _MainTex_ST.zw) * _Color;
	ALBEDO = col.rgb;
}
