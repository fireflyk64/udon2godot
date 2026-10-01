// Port of "metaphira/Scorecard" (MS-VRCSA-Billiards, Shaders/Scorecard.shader): the lamps on the
// table's side. The texture of the game mode has one lamp per ball (red: its white rim, green /
// blue: its body, blue: the stripe); the lamps up to each side's score are lit in the colours
// the script hands over (_Colors, left to right), stripes white for the side that plays them.
shader_type spatial;
render_mode unshaded;

uniform sampler2D _EightBallTex : hint_default_white, filter_linear_mipmap;
uniform sampler2D _NineBallTex : hint_default_white, filter_linear_mipmap;
uniform sampler2D _FourBallTex : hint_default_white, filter_linear_mipmap;
uniform int _GameMode = 0;     // 0 eight ball, 1 nine ball, 2 four ball, 3 four ball (KR), 4 snooker
uniform int _LeftScore = 0;
uniform int _RightScore = 0;
uniform int _SolidsMode = 0;   // 0 both, 1 left, 2 right
uniform vec4 _Colors[15] : source_color;

const float OFFSET = 0.03125;

void fragment() {
	vec4 base = vec4(0.0);
	float left_end = 0.0;
	float right_end = 0.0;
	bool shown = true;
	if (_GameMode == 0) {
		base = texture(_EightBallTex, UV);
		left_end = float(_LeftScore) * 0.0625;
		right_end = float(_RightScore) * 0.0625;
	} else if (_GameMode == 1) {
		base = texture(_NineBallTex, UV);
	} else if (_GameMode == 2 || _GameMode == 3) {
		base = texture(_FourBallTex, UV);
		left_end = float(_LeftScore) * 0.04681905;
		right_end = float(_RightScore) * 0.04681905;
	} else {
		shown = false;
	}
	vec3 color = vec3(0.0);
	if (shown) {
		float body = round(length(base.gb));
		float left_start = UV.x - OFFSET;
		if (left_start < left_end) {
			int index = _GameMode == 0 ? clamp(int(left_start / 0.0625), 0, 14) : 0;
			if (_SolidsMode == 2 && round(base.b) > 0.5 && index != 7) {
				color += vec3(1.0);   // a stripe on the left, unless it is the eight ball
			} else {
				color += _Colors[index].rgb * body;
			}
		}
		float right_start = 1.0 - UV.x - OFFSET;
		if (right_start < right_end) {
			int index = _GameMode == 0 ? clamp(int(15.0 - right_start / 0.0625), 0, 14) : 1;
			if (_SolidsMode == 1 && round(base.b) > 0.5 && index != 7) {
				color += vec3(1.0);
			} else {
				color += _Colors[index].rgb * body;
			}
		}
		color += vec3(base.r);
	}
	ALBEDO = color;
}
