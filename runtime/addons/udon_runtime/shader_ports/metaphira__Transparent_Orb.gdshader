// Port of "metaphira/Transparent Orb" (MS-VRCSA-Billiards): additive rim glow.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;

uniform vec4 _Color : source_color = vec4(1.0);
uniform float _FresnelBias = 0.0;
uniform float _FresnelScale = 1.0;
uniform float _FresnelPower = 1.0;

varying float fresnel;

void vertex() {
	vec3 cam_obj = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 i = normalize(cam_obj - VERTEX);
	fresnel = _FresnelBias + _FresnelScale * pow(max(1.0 + dot(i, NORMAL), 0.0), _FresnelPower);
}

void fragment() {
	float k = clamp(1.0 - fresnel, 0.0, 1.0);
	ALBEDO = _Color.rgb * k;
	ALPHA = 1.0;
}
