// Port of "metaphira/TableSurface" (MS-VRCSA-Billiards, Shaders/TableSurface.shader): the table
// body and cloth. The albedo's alpha is a tint map (the cloth takes _Color), an optional cloth
// detail texture is multiplied in where the cloth mask says so, the cloth can be hue-shifted
// (in Oklab) and saturated, and the rim lights (_EmissionMap) go out around the table as the
// shot timer (_TimerPct) runs down.
shader_type spatial;

uniform vec4 _EmissionColor : source_color = vec4(1.0);
uniform vec4 _Color : source_color = vec4(1.0);
uniform sampler2D _MainTex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D _EmissionMap : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D _Metalic : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float _UseDetailCloth = 0.0;   // the DETAIL_CLOTH keyword
uniform sampler2D _DetailCloth : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 _DetailCloth_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _ClothHue : hint_range(0.0, 1.0) = 0.0;
uniform float _ClothSaturation : hint_range(0.0, 3.0) = 1.0;
uniform float _DetailClothBrightness : hint_range(0.0, 2.0) = 1.0;
uniform sampler2D _DetailClothMask : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float _MaskStrengthCloth : hint_range(0.0, 1.0) = 1.0;
uniform float _UseDetailOther = 0.0;   // the DETAIL_OTHER keyword
uniform sampler2D _DetailOther : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 _DetailOther_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _DetailOtherBrightness : hint_range(0.0, 2.0) = 1.0;
uniform float _MaskStrengthOther : hint_range(0.0, 1.0) = 1.0;
uniform float _TimerPct : hint_range(0.0, 1.0) = 1.0;

// unity_ColorSpaceDouble in a linear project: detail textures are "times two" around mid grey
const float COLOR_SPACE_DOUBLE = 4.59479380;

varying vec3 model_pos;

void vertex() {
	// Unity's object space: the importer mirrors x
	model_pos = vec3(-VERTEX.x, VERTEX.y, VERTEX.z);
}

vec3 linear_srgb_to_oklab(vec3 c) {
	float l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z;
	float m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z;
	float s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z;
	float l_ = pow(l, 1.0 / 3.0);
	float m_ = pow(m, 1.0 / 3.0);
	float s_ = pow(s, 1.0 / 3.0);
	return vec3(
		0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
		1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
		0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_);
}

vec3 oklab_to_linear_srgb(vec3 c) {
	float l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
	float m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
	float s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
	float l = l_ * l_ * l_;
	float m = m_ * m_ * m_;
	float s = s_ * s_ * s_;
	return vec3(
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

vec3 hue_shift(vec3 color, float shift) {
	vec3 oklab = linear_srgb_to_oklab(max(color, vec3(0.0000000001)));
	float hue = atan(oklab.z, oklab.y) + shift * TAU;
	float chroma = length(oklab.yz);
	oklab.y = cos(hue) * chroma;
	oklab.z = sin(hue) * chroma;
	return oklab_to_linear_srgb(oklab);
}

vec3 saturation(vec3 c, float amount) {
	float luma = dot(c, vec3(0.2126729, 0.7151522, 0.0721750));
	return vec3(luma) + amount * (c - vec3(luma));
}

void fragment() {
	vec4 diffuse = texture(_MainTex, UV);
	vec4 emission = texture(_EmissionMap, UV);
	vec4 metalic = texture(_Metalic, UV);
	vec3 final = mix(diffuse.rgb, _Color.rgb * diffuse.rgb * 2.0, pow(diffuse.a, 0.1));
	if (_UseDetailCloth > 0.5) {
		// (the Unity source reads the offset as _ST.wz)
		vec3 detail = texture(_DetailCloth, UV * _DetailCloth_ST.xy + _DetailCloth_ST.wz).rgb * COLOR_SPACE_DOUBLE * _DetailClothBrightness;
		float cloth_mask = texture(_DetailClothMask, UV).r;
		final = mix(final, final * detail, cloth_mask * _MaskStrengthCloth);
		vec3 cloth = final * cloth_mask;
		vec3 other = final * (1.0 - cloth_mask);
		cloth = saturation(hue_shift(cloth, _ClothHue), _ClothSaturation);
		final = cloth + other;
		if (_UseDetailOther > 0.5) {
			vec3 detail_other = texture(_DetailOther, UV * _DetailOther_ST.xy + _DetailOther_ST.wz).rgb * COLOR_SPACE_DOUBLE * _DetailOtherBrightness;
			final = mix(final, final * detail_other, (1.0 - cloth_mask) * _MaskStrengthOther);
		}
	}
	ALBEDO = max(final, vec3(0.0));
	METALLIC = metalic.r;
	ROUGHNESS = 1.0 - metalic.a;
	// the rim lights: lit from the timer's angle on (a small fudge factor so that the light connects)
	float timer_pct = clamp(_TimerPct, 0.0, 1.0);
	float surf_angle_pct = (PI + atan(model_pos.x, model_pos.z)) / TAU / 1.04 + (1.0 - 1.0 / 1.04);
	float angle_cl = clamp((surf_angle_pct - timer_pct) * 40.0, 0.0, 1.5);
	EMISSION = emission.rgb * _EmissionColor.rgb * angle_cl;
}
