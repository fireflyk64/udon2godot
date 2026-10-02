// Port of "CF-Pool/Fur" (vrcbce, Shaders/CottonFoxFur.shader, by Juice): the surface below the
// fur. The shells of the fur are further passes: CF_Pool__Fur.pass1.gdshader.
shader_type spatial;
render_mode cull_back;

#include "CF_Pool__Fur.gdshaderinc"

void fragment() {
	vec3 albedo;
	vec3 emission;
	fur_surface(UV, 0.0, albedo, emission);
	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = 1.0 - _Gloss;
	SPECULAR = _Specular;
}
