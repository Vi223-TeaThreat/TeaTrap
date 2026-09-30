shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, world_vertex_coords;

// =============================================================================
//  ДОЖДЬ (погода «дождь», 15.09.2026).
//
//  Капля в меше — четыре точки в одном месте короба, доли от 0 до 1 (см.
//  `_rain_mesh` в `Weather.gd`). Всё остальное делает этот шейдер, и процессору
//  дождь не стоит ничего:
//
//    • РОНЯЕТ: место капли едет вниз и чуть по ветру своей скоростью;
//    • ЗАВОРАЧИВАЕТ В КОРОБ вокруг точки взгляда. Короб ходит за камерой, а капли
//      стоят в МИРЕ: место считается по миру и лишь заворачивается в короб. Иначе
//      дождь ездил бы вместе с камерой, как грязь на стекле;
//    • ВЫТЯГИВАЕТ В ЧЕРТУ вдоль падения, лицом к глазу, толщиной не тоньше точки
//      экрана — иначе издали дождь пропадал бы весь;
//    • ГАСИТ у стенок короба, у самого глаза и те капли, чья очередь ещё не
//      пришла (`rain` густеет при смене погоды).
// =============================================================================

uniform float rain_time = 0.0;
uniform float rain = 0.0;                            // густота: 0 — ни капли, 1 — ливень
uniform vec3 rain_center = vec3(0.0);
uniform vec3 rain_box = vec3(44.0, 28.0, 44.0);
uniform vec2 wind = vec2(0.8, 0.6);
uniform float slant = 0.15;                          // насколько косит ветер
uniform float fall = 9.0;                            // скорость падения, м/с
uniform vec4 drop_color : source_color = vec4(0.78, 0.82, 0.86, 0.42);

varying float v_fade;

void vertex() {
	vec3 dir = normalize(vec3(wind.x * slant, -1.0, wind.y * slant));
	vec3 corner = rain_center - rain_box * vec3(0.5, 0.4, 0.5);
	vec3 raw = VERTEX * rain_box + dir * (fall * (0.85 + 0.3 * COLOR.g) * rain_time);
	vec3 local = mod(raw - corner, rain_box);
	vec3 drop = corner + local;
	vec3 to_eye = INV_VIEW_MATRIX[3].xyz - drop;
	float dist = max(length(to_eye), 0.001);
	vec3 side = cross(dir, to_eye / dist);
	float side_len = length(side);
	side = side_len > 0.0001 ? side / side_len : vec3(1.0, 0.0, 0.0);
	float len = 0.45 + 0.35 * COLOR.b;
	float wide = max(0.008, dist * 0.0012);
	float keep = step(COLOR.r, rain);
	VERTEX = drop + (dir * ((UV.y - 0.5) * len) + side * (UV.x * wide * 0.5)) * keep;
	float edge = min(min(local.x, rain_box.x - local.x), min(local.z, rain_box.z - local.z));
	float rise = min(local.y, rain_box.y - local.y);
	v_fade = keep * clamp(edge / (rain_box.x * 0.15), 0.0, 1.0)
		* clamp(rise / (rain_box.y * 0.12), 0.0, 1.0)
		* smoothstep(0.5, 2.0, dist);
}

void fragment() {
	// К концам черта тоньше светом: так она читается каплей в движении, а не палкой.
	float along = 1.0 - abs(UV.y * 2.0 - 1.0);
	ALBEDO = drop_color.rgb;
	ALPHA = drop_color.a * v_fade * (0.3 + 0.7 * along);
}
