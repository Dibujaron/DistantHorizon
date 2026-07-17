// Quantized 3-step directional shading for lit hull sprites — the engine
// version of lightspike.py's offline math. The base pass paints the sprite at
// the shadow step; the DirectionalLight2D pass (blend mode Add) adds the
// difference up to mid/lit per pixel, so total = albedo * step, same as the
// offline sheet. Thresholds and step colors must match lightspike.py.
shader_type canvas_item;

const vec3 STEP_LIT = vec3(1.20, 1.10, 0.95);
const vec3 STEP_MID = vec3(0.74, 0.74, 0.82);
const vec3 STEP_SHADOW = vec3(0.34, 0.38, 0.58);

void fragment() {
	COLOR.rgb *= STEP_SHADOW;
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
