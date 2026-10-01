// Port of "metaphira/Timer" (MS-VRCSA-Billiards, Shaders/Timer.shader): a bar whose texture
// holds its fill order in red and its frame in green; what lies beyond _TimeFrac glows.
shader_type spatial;

uniform vec4 _Color : source_color = vec4(1.0);
uniform sampler2D _MainTex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float _Glossiness : hint_range(0.0, 1.0) = 0.5;
uniform float _Metallic : hint_range(0.0, 1.0) = 0.0;
uniform float _TimeFrac : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 c = texture(_MainTex, UV);
	float colourterm = clamp((c.r - _TimeFrac) * 12.0, 0.0, 1.0);
	ALBEDO = mix(_Color.rgb * colourterm, vec3(1.0), c.g);
	METALLIC = _Metallic;
	ROUGHNESS = 1.0 - _Glossiness;
	EMISSION = colourterm * (1.0 - c.g) * _Color.rgb;
}
