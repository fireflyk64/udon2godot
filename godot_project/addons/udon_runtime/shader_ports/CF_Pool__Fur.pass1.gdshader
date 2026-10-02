// Port of "CF-Pool/Fur" (vrcbce): one shell of the fur, the surface pushed out along its
// normals by FURSTEP of the fur's length and cut where the fur map (second UV set) has no
// hair that long. Unity draws fifteen shells and blends them; here each is cut at an alpha
// that leaves about what the blended shells add up to.
// unidot_repeat: FURSTEP = 0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00
shader_type spatial;
render_mode cull_back;

#include "CF_Pool__Fur.gdshaderinc"

uniform float FURSTEP = 0.05;
uniform sampler2D _FurMap : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _FurMap_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _Density : hint_range(0.0, 1.0) = 0.5;
uniform float _Length : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	VERTEX += NORMAL * (_Length / 10.0) * FURSTEP;
}

void fragment() {
	vec3 albedo;
	vec3 emission;
	fur_surface(UV, FURSTEP, albedo, emission);
	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = 1.0 - _Gloss;
	SPECULAR = _Specular;
	ALPHA = clamp(texture(_FurMap, UV2 * _FurMap_ST.xy + _FurMap_ST.zw).r - FURSTEP * FURSTEP * _Density, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.2;
}
