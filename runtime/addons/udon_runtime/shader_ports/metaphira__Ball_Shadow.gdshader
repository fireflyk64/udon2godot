// Port of "metaphira/Ball Shadow" (MS-VRCSA-Billiards, Shaders/BallShadow.shader).
// The shadow quad is part of the ball mesh; the vertex stage flattens it onto the table plane at
// world height _Floor around the ball's origin, ignoring the ball's rotation, and fades it as the
// ball lifts off the surface.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform sampler2D _MainTex : source_color, filter_linear_mipmap;
uniform float _Floor = 0.0;
uniform float _Scale = 1.0;

varying float intensity;

void vertex() {
	float ball_radius = 0.03 * _Scale;
	float ball_origin_y = _Floor + ball_radius;
	vec3 shadow_origin = MODEL_MATRIX[3].xyz;
	intensity = 1.0 - clamp(abs(shadow_origin.y - ball_origin_y), 0.0, ball_radius) / ball_radius;
	vec3 world = vec3(VERTEX.x * _Scale + shadow_origin.x, _Floor + 0.0005, VERTEX.z * _Scale + shadow_origin.z);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	vec4 c = texture(_MainTex, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a * intensity;
}
