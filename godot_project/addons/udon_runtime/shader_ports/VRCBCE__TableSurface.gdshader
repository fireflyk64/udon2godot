// Port of "VRCBCE/TableSurface" (vrcbce, Shaders/tablesurface.shader): a table whose cloth takes
// _ClothColour where the green channel of _EmissionMap says "cloth", and whose rim lights (the
// red channel) go out around the table as the alpha of _EmissionColour (the shot timer) grows.
shader_type spatial;

uniform vec4 _EmissionColour : source_color = vec4(1.0);
uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform sampler2D _MetallicMap : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D _EmissionMap : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _ClothColour : source_color = vec4(1.0);

varying vec3 model_pos;

void vertex() {
	// Unity's object space: the importer mirrors x
	model_pos = vec3(-VERTEX.x, VERTEX.y, VERTEX.z);
}

void fragment() {
	vec2 uv = UV * _MainTex_ST.xy + _MainTex_ST.zw;
	vec4 c = texture(_MainTex, uv);
	float xy_angle = (atan(model_pos.x, model_pos.z) + 3.4) * 0.14915494309;
	float angle_cl = clamp((xy_angle - _EmissionColour.a) * 40.0, 0.0, 1.0);
	vec4 metallic_smoothness = texture(_MetallicMap, uv);
	vec4 emit = texture(_EmissionMap, uv);
	ALBEDO = mix(c.rgb, _ClothColour.rgb * c.rgb * 2.0, pow(emit.g, 0.1));
	METALLIC = metallic_smoothness.r;
	ROUGHNESS = 1.0 - metallic_smoothness.a;
	EMISSION = emit.r * _EmissionColour.rgb * angle_cl;
}
