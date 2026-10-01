// Port of "VRCBCE/Surface Color Mask" (vrcbce, Shaders/CustomColorMask.shader, made with Amplify
// Shader Editor): the ball atlas with the team colours replaced by _BallColour where _ColourMask
// says so (_CustomColor is 0 for the custom colour, -1 for the texture's own), except where
// _ConstMask keeps the texture (numbers, the black ball); _Turnoff shows the plain texture.
shader_type spatial;

uniform float _Turnoff : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 _BallColour : source_color = vec4(1.0, 0.0, 0.0, 0.0);
uniform float _CustomColor : hint_range(-1.0, 0.0) = -1.0;
uniform sampler2D _ColourMask : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec4 _ColourMask_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform sampler2D _ConstMask : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec4 _ConstMask_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform sampler2D _emissionmap : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _emissionmap_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 _Emission : source_color = vec4(0.0);
uniform sampler2D _normalmap : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 _normalmap_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform sampler2D _metalic : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec4 _metalic_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _Smoothness : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 tex = texture(_MainTex, UV * _MainTex_ST.xy + _MainTex_ST.zw);
	vec4 keep = texture(_ConstMask, UV * _ConstMask_ST.xy + _ConstMask_ST.zw);
	vec4 mask = texture(_ColourMask, UV * _ColourMask_ST.xy + _ColourMask_ST.zw);
	float own = abs(_CustomColor);
	vec4 without_mask = clamp(tex - (mask - vec4(own)), vec4(0.0), vec4(1.0, 1.0, 1.0, 0.0));
	vec4 tinted = without_mask + (1.0 - own) * (mask * _BallColour);
	vec4 albedo = tex * _Turnoff + ((vec4(1.0) - keep) * tinted + keep * tex) * (1.0 - _Turnoff);
	ALBEDO = albedo.rgb;
	NORMAL_MAP = texture(_normalmap, UV * _normalmap_ST.xy + _normalmap_ST.zw).rgb;
	EMISSION = (texture(_emissionmap, UV * _emissionmap_ST.xy + _emissionmap_ST.zw) * _Emission).rgb;
	METALLIC = texture(_metalic, UV * _metalic_ST.xy + _metalic_ST.zw).r;
	ROUGHNESS = 1.0 - _Smoothness;
}
