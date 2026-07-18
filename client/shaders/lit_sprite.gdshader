// Quantized 3-step directional shading for lit hull sprites — the engine
// version of the composer's offline math. The base pass paints the sprite at
// the shadow step; each DirectionalLight2D pass (blend mode Add) adds the
// difference up to mid/lit per pixel, so total = albedo * step per sun.
// Thresholds and step colors must match composer.py.
//
// Livery: mask_tex R selects the c1 channel, G the c2 channel. Tinting is a
// relative recolor (albedo * tint / base) applied in fragment(), so light()
// — which recovers albedo by dividing out STEP_SHADOW — stays consistent
// automatically. c1_base/c2_base come from the ship's meta.json.
shader_type canvas_item;

const vec3 STEP_LIT = vec3(1.20, 1.10, 0.95);
const vec3 STEP_MID = vec3(0.74, 0.74, 0.82);
const vec3 STEP_SHADOW = vec3(0.34, 0.38, 0.58);

uniform sampler2D mask_tex : filter_nearest;
uniform vec3 c1_tint : source_color = vec3(0.231, 0.553, 0.878);
uniform vec3 c2_tint : source_color = vec3(0.933, 0.949, 0.965);
uniform vec3 c1_base : source_color = vec3(0.231, 0.553, 0.878);
uniform vec3 c2_base : source_color = vec3(0.933, 0.949, 0.965);

void fragment() {
	vec2 m = texture(mask_tex, UV).rg;
	vec3 albedo = COLOR.rgb;
	albedo = mix(albedo, albedo * c1_tint / max(c1_base, vec3(1e-3)), m.r);
	albedo = mix(albedo, albedo * c2_tint / max(c2_base, vec3(1e-3)), m.g);
	COLOR.rgb = albedo * STEP_SHADOW;
}

void light() {
	// LIGHT_DIRECTION points toward the light (3D convention)
	float d = clamp(dot(normalize(NORMAL), normalize(LIGHT_DIRECTION)), 0.0, 1.0);
	vec3 step_mult;
	if (d >= 0.62) {
		step_mult = STEP_LIT;
	} else if (d >= 0.32) {
		step_mult = STEP_MID;
	} else {
		step_mult = STEP_SHADOW;
	}
	// COLOR here is the fragment() output (albedo * shadow); recover albedo.
	// LIGHT.a must be 1.0 — it scales the whole contribution (0.0 = no light)
	vec3 albedo = COLOR.rgb / STEP_SHADOW;
	LIGHT = vec4(albedo * (step_mult - STEP_SHADOW) * LIGHT_COLOR.rgb, 1.0);
}
