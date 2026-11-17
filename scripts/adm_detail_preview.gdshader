shader_type spatial;
render_mode cull_disabled;

uniform sampler2D detail_texture : source_color, repeat_enable, filter_linear;
uniform sampler2D base_texture : source_color, repeat_enable, filter_linear;
uniform sampler2D emissive_texture : source_color, repeat_enable, filter_linear;
uniform sampler2D roughness_texture : repeat_enable, filter_linear;
uniform bool has_base_texture = false;
uniform bool has_emissive_texture = false;
uniform bool has_roughness_texture = false;
uniform vec4 base_factor = vec4(1.0);
uniform vec3 emissive_factor = vec3(0.0);
uniform vec3 detail_factor = vec3(0.72);
uniform float detail_strength = 1.0;
uniform float base_metallic = 1.0;
uniform float base_roughness = 1.0;
uniform float detail_metallic = 0.0;
uniform float detail_roughness = 0.6;
uniform int roughness_channel = 0;
uniform bool roughness_invert = false;

void fragment() {
	vec4 base = base_factor;
	if (has_base_texture) {
		base *= texture(base_texture, UV);
	}
	vec4 detail = texture(detail_texture, UV);
	float weight = clamp(COLOR.r * detail_strength, 0.0, 1.0);
	ALBEDO = mix(base.rgb, detail.rgb * detail_factor, weight);
	METALLIC = mix(base_metallic, detail_metallic, weight);
	float mapped_roughness = detail_roughness;
	if (has_roughness_texture) {
		float sample_value = texture(roughness_texture, UV)[roughness_channel];
		mapped_roughness *= roughness_invert ? 1.0 - sample_value : sample_value;
	}
	ROUGHNESS = mix(base_roughness, mapped_roughness, weight);
	EMISSION = emissive_factor;
	if (has_emissive_texture) {
		EMISSION *= texture(emissive_texture, UV).rgb;
	}
}
