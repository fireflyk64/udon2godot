// Port of "VRCBCE/Ghost Balls" (vrcbce, Shaders/GhostBalls.shader): the placement marker and
// the cue's grip and hit indicators, drawn additively. The colour fades towards the rim:
// lerp(0, _Color, saturate(1 - fresnel)), fresnel = bias + scale * pow(1 + dot(I, N), power)
// with I the direction from the camera's side to the surface as Unity's ObjSpaceViewDir gives
// it (pointing at the camera).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;

uniform vec4 _Color : source_color = vec4(1.0);
uniform float _FresnelBias = 0.0;
uniform float _FresnelScale = 1.0;
uniform float _FresnelPower = 1.0;

void fragment() {
	float facing = dot(normalize(VIEW), normalize(NORMAL));
	float fresnel = _FresnelBias + _FresnelScale * pow(max(1.0 + facing, 0.0), _FresnelPower);
	ALBEDO = _Color.rgb * clamp(1.0 - fresnel, 0.0, 1.0);
}
