// Port of "VRCBCE/Surface Color Mask (Fur)" (vrcbce): the hull. The back faces of the mesh,
// pushed out along the normals by _FurAmount / 100 of what _FurNoise says, in the unlit colour
// of the surface.
shader_type spatial;
render_mode cull_front, unshaded, shadows_disabled;

uniform float _Turnoff : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 _BallColour : source_color = vec4(1.0, 0.0, 0.0, 0.0);
uniform float _CustomColor : hint_range(-1.0, 0.0) = -1.0;
uniform sampler2D _ColourMask : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec4 _ColourMask_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform sampler2D _ConstMask : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec4 _ConstMask_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _FurAmount : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D _FurNoise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _FurNoise_ST = vec4(1.0, 1.0, 0.0, 0.0);

void vertex() {
	VERTEX += NORMAL * (_FurAmount / 100.0) * textureLod(_FurNoise, UV * _FurNoise_ST.xy + _FurNoise_ST.zw, 0.0).r;
}

void fragment() {
	vec4 tex = texture(_MainTex, UV * _MainTex_ST.xy + _MainTex_ST.zw);
	vec4 keep = texture(_ConstMask, UV * _ConstMask_ST.xy + _ConstMask_ST.zw);
	vec4 mask = texture(_ColourMask, UV * _ColourMask_ST.xy + _ColourMask_ST.zw);
	float own = abs(_CustomColor);
	vec4 without_mask = clamp(tex - (mask - vec4(own)), vec4(0.0), vec4(1.0, 1.0, 1.0, 0.0));
	vec4 tinted = without_mask + (1.0 - own) * (mask * _BallColour);
	ALBEDO = (tex * _Turnoff + ((vec4(1.0) - keep) * tinted + keep * tex) * (1.0 - _Turnoff)).rgb;
}
