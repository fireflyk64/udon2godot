// Port of "Custom/StandardScrollingEmissive" (vrcbce, Shaders/ScrollingEmissive.shader): a
// standard surface whose emission texture, on the second UV set, scrolls with time (Unity's
// _Time is (t / 20, t, 2t, 3t) and the shader takes all of it: the x component moves the
// texture, t / 20 per unit of _ScrollX / _ScrollY). The normal map is on the third UV set in
// Unity; meshes are imported with two, so it uses the first.
shader_type spatial;

uniform vec4 _Color : source_color = vec4(1.0);
uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 _EmissionColor : source_color = vec4(1.0);
uniform sampler2D _EmissionTex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _EmissionTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _EmissionBoost : hint_range(0.0, 5.0) = 0.0;
uniform float _ScrollX : hint_range(-5.0, 5.0) = 0.0;
uniform float _ScrollY : hint_range(-5.0, 5.0) = 0.0;
uniform sampler2D _BumpMap : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 _BumpMap_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _BumpScale = 1.0;
uniform float _Glossiness : hint_range(0.0, 1.0) = 0.0;
uniform float _Metallic : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 scrolled = UV2 * _EmissionTex_ST.xy + _EmissionTex_ST.zw + fract(vec2(_ScrollX, _ScrollY) * (TIME / 20.0));
	EMISSION = (texture(_EmissionTex, scrolled) * _EmissionColor).rgb * (_EmissionBoost + 1.0);
	ALBEDO = (texture(_MainTex, UV * _MainTex_ST.xy + _MainTex_ST.zw) * _Color).rgb;
	NORMAL_MAP = texture(_BumpMap, UV * _BumpMap_ST.xy + _BumpMap_ST.zw).rgb;
	NORMAL_MAP_DEPTH = _BumpScale;
	METALLIC = _Metallic;
	ROUGHNESS = 1.0 - _Glossiness;
}
