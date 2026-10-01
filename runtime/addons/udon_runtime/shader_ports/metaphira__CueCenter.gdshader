// Port of "metaphira/CueCenter" (MS-VRCSA-Billiards, Shaders/CueCenter.shader): a glossy marker
// that reflects its surroundings in a colour. The Unity shader samples a cubemap of its own
// with a fresnel term; here the scene's reflections stand in for it.
shader_type spatial;

uniform vec4 _ReColor : source_color = vec4(1.0);
uniform float _FresnelBias = 0.0;
uniform float _FresnelScale = 1.0;
uniform float _FresnelPower = 1.0;
uniform float _Exposure : hint_range(0.0, 8.0) = 1.0;

void fragment() {
	float facing = clamp(dot(normalize(VIEW), normalize(NORMAL)), 0.0, 1.0);
	float fresnel = clamp(_FresnelBias + _FresnelScale * pow(1.0 + facing, _FresnelPower), 0.0, 1.0);
	ALBEDO = _ReColor.rgb;
	METALLIC = 1.0;
	ROUGHNESS = 0.2;
	EMISSION = _ReColor.rgb * fresnel * 0.4 * _Exposure;
}
