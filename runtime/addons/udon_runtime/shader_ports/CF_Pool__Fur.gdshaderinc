// Shared by the passes of the port of "CF-Pool/Fur" (vrcbce, Shaders/CottonFoxFur.shader and
// CottonFoxFur.cginc, by Juice): the colour of the surface and of a shell of the fur at
// FURSTEP (0 at the skin, 1 at the tips), which the including shader defines.
uniform float _Emission : hint_range(0.0, 1.0) = 0.5;
uniform float _Hue : hint_range(0.0, 360.0) = 0.0;
uniform float _Sat : hint_range(0.0, 1.0) = 1.0;
uniform float _Invert : hint_range(0.0, 1.0) = 0.0;
uniform float _Specular : hint_range(0.0, 1.0) = 0.25;
uniform float _Gloss : hint_range(0.0, 1.0) = 0.5;
uniform vec4 _Color : source_color = vec4(1.0);
uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _Shading : hint_range(0.0, 1.0) = 0.25;

float fur_alt(float n, vec3 hsv) {
	float k = mod(n + hsv.x / 60.0, 6.0);
	return hsv.z - hsv.z * hsv.y * max(0.0, min(min(k, 4.0 - k), 1.0));
}

// the texture's colour with its hue turned by _Hue and its saturation scaled by _Sat
vec3 fur_conv(vec3 clr) {
	float mx = max(clr.r, max(clr.g, clr.b));
	float mn = min(clr.r, min(clr.g, clr.b));
	vec3 hsv = vec3(0.0, 0.0, mx);
	float c = mx - mn;
	if (c > 0.0) {
		if (hsv.z == clr.r) {
			hsv.x = 60.0 * ((clr.g - clr.b) / c);
		} else if (hsv.z == clr.g) {
			hsv.x = 60.0 * (2.0 + (clr.b - clr.r) / c);
		} else {
			hsv.x = 60.0 * (4.0 + (clr.r - clr.g) / c);
		}
	}
	if (hsv.z != 0.0) {
		hsv.y = c / hsv.z;
	}
	hsv.x += _Hue;
	if (hsv.x > 360.0) {
		hsv.x -= 360.0;
	}
	hsv.y *= _Sat;
	return vec3(fur_alt(5.0, hsv), fur_alt(3.0, hsv), fur_alt(1.0, hsv));
}

// albedo and emission of the surface (the shader's own lighting is left to the engine):
// darker towards the skin by _Shading
void fur_surface(vec2 uv, float furstep, out vec3 albedo, out vec3 emission) {
	vec3 base = abs(vec3(_Invert) - fur_conv(texture(_MainTex, uv * _MainTex_ST.xy + _MainTex_ST.zw).rgb) * _Color.rgb);
	emission = base * _Emission;
	albedo = max(base - vec3(pow(1.0 - furstep, 2.0) * _Shading), vec3(0.0));
}
