// twilight.wgsl — Twilight Zone clock with three large engraved rings.
//
// Each ring is a thin gold band — picture the One Ring lying flat — with
// a vertical rotation axis and engravings around its outer cylindrical
// surface. The camera is elevated slightly above the rings' planes, so
// each ring projects to a tilted ellipse on screen. We see the engraved
// outer surface on the front-facing arc of every ring, and the engravings
// sweep across that arc as the ring rotates.
//
// The three rings (hours / minutes / seconds) are stacked vertically but
// each drifts in (x, y) and tilts at its own slow oscillation, so they
// float and wobble independently and never sit perfectly concentric.
// Their on-screen silhouettes can overlap, but their engraving zones
// land at different vertical heights so the readout stays clean.
//
// Each ring rotates at the rate of its time unit:
//   * hours:   1 revolution / 12 hours
//   * minutes: 1 revolution / hour
//   * seconds: 1 revolution / minute
//
// The current value sits at the front of the ring (phi = π/2). Engravings
// outside a fixed visibility cone around the front fade out.

struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    _pad: f32,
    angles: vec4<f32>,  // x = h*(TAU/12), y = m*(TAU/60), z = s*(TAU/60)
};

@group(0) @binding(0) var<uniform> u: Uniforms;

const PI: f32 = 3.14159265358979;
const TAU: f32 = 6.28318530717958;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    let x = f32((vi << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(vi & 2u) * 2.0 - 1.0;
    return vec4<f32>(x, y, 0.0, 1.0);
}

fn hash21(p: vec2<f32>) -> f32 {
    let h = dot(p, vec2<f32>(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

fn sdf_box(p: vec2<f32>, c: vec2<f32>, b: vec2<f32>) -> f32 {
    let q = abs(p - c) - b;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0);
}

// 7-segment lookup: bit 0=a, 1=b, 2=c, 3=d, 4=e, 5=f, 6=g.
fn seg_mask(d: i32) -> u32 {
    var m: u32 = 0u;
    if (d == 0) { m = 0x3Fu; }
    if (d == 1) { m = 0x06u; }
    if (d == 2) { m = 0x5Bu; }
    if (d == 3) { m = 0x4Fu; }
    if (d == 4) { m = 0x66u; }
    if (d == 5) { m = 0x6Du; }
    if (d == 6) { m = 0x7Du; }
    if (d == 7) { m = 0x07u; }
    if (d == 8) { m = 0x7Fu; }
    if (d == 9) { m = 0x6Fu; }
    return m;
}

// 7-segment digit. Cell occupies x in [-0.5, 0.5], y in [-1.0, 1.0].
fn digit(p: vec2<f32>, value: i32) -> f32 {
    let m = seg_mask(value);
    let bh = vec2<f32>(0.42, 0.07);
    let bv = vec2<f32>(0.07, 0.42);
    var d = 1e9;
    if ((m & 0x01u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.0,  1.0), bh)); }
    if ((m & 0x02u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.5,  0.5), bv)); }
    if ((m & 0x04u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.5, -0.5), bv)); }
    if ((m & 0x08u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.0, -1.0), bh)); }
    if ((m & 0x10u) != 0u) { d = min(d, sdf_box(p, vec2<f32>(-0.5, -0.5), bv)); }
    if ((m & 0x20u) != 0u) { d = min(d, sdf_box(p, vec2<f32>(-0.5,  0.5), bv)); }
    if ((m & 0x40u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.0,  0.0), bh)); }
    let core = 1.0 - smoothstep(0.0, 0.07, d);
    let glow = smoothstep(0.30, 0.0, d) * 0.18;
    return max(core, glow);
}

// Brightness contribution of an engraved ring at the current pixel.
//
// World layout: ring centered at (cx, cy) on screen, lying flat in the
// world's XZ plane with vertical rotation axis. Camera is elevated by
// `alpha` above horizontal. The ring has major radius R and an outer
// cylindrical surface of axial half-width h that carries the engravings.
//
// For each pixel we:
//   1. Solve the projection to recover (X, Z) on the ring's circle and the
//      Y axial position on the band — separately for the front (Z>0) and
//      back (Z<0) halves of the ring.
//   2. If the front intersects the band, compute the angular position
//      phi = atan2(Z, X) and find which engraved slot the pixel falls in.
//      Render that digit in slot-local (arc, axial) coords.
//   3. If the back intersects the band but the front doesn't, draw a
//      faint silhouette only — no engravings, since the outer surface
//      points away from the camera there.
fn ring_brightness(
    uv: vec2<f32>,
    cx: f32, cy: f32,
    R: f32, h: f32, alpha: f32,
    n_slots: i32,
    ring_rot: f32,
) -> f32 {
    let dx = uv.x - cx;
    if (abs(dx) >= R * 0.998) { return 0.0; }

    let s_alpha = sin(alpha);
    let c_alpha = cos(alpha);
    let Zf = sqrt(R * R - dx * dx);
    let dy = uv.y - cy;

    // Two candidate band intersections at this column.
    let y_front = (dy + Zf * s_alpha) / c_alpha;
    let y_back  = (dy - Zf * s_alpha) / c_alpha;
    let in_front = abs(y_front) <= h;
    let in_back  = abs(y_back)  <= h;

    if (!in_front && !in_back) { return 0.0; }

    var contribution: f32 = 0.0;

    if (in_front) {
        let axial_fade = smoothstep(h, h * 0.85, abs(y_front));
        let phi_pix = atan2(Zf, dx);  // (0, π): 0 = right side, π/2 = front, π = left

        let win = 0.55;
        let phi_dist = abs(phi_pix - PI * 0.5);
        let visib_fade = smoothstep(win, win * 0.20, phi_dist);

        let local_angle = phi_pix - ring_rot;
        let slot_pitch = TAU / f32(n_slots);
        let slot_idx = i32(floor(local_angle / slot_pitch + 0.5));
        let slot_center = f32(slot_idx) * slot_pitch;
        let dtheta = local_angle - slot_center;

        var value = slot_idx % n_slots;
        if (value < 0) { value = value + n_slots; }

        // Digit-local frame: x = -R*dtheta so digit-local +x lines up with
        // screen +x at phi = π/2 (otherwise digits read backwards at the
        // front of the ring); y = axial position on the band.
        let arc_dist = -R * dtheta;
        let scale = 60.0;
        let local = vec2<f32>(arc_dist, y_front) * scale;

        var d_int: f32 = 0.0;
        if (n_slots == 12) {
            // Hours: display 1..12 (slot 0 → 12), centered single digit if < 10.
            var hv = value;
            if (hv == 0) { hv = 12; }
            if (hv < 10) {
                d_int = digit(local, hv);
            } else {
                let p_tens = local - vec2<f32>(-0.6, 0.0);
                let p_ones = local - vec2<f32>( 0.6, 0.0);
                d_int = max(digit(p_tens, hv / 10), digit(p_ones, hv % 10));
            }
        } else {
            // Minutes / seconds: always two digits, 00..59.
            let p_tens = local - vec2<f32>(-0.6, 0.0);
            let p_ones = local - vec2<f32>( 0.6, 0.0);
            d_int = max(digit(p_tens, value / 10), digit(p_ones, value % 10));
        }

        let mask = visib_fade * axial_fade;
        contribution = d_int * mask * 0.95 + mask * 0.06;
    } else {
        // Back-of-ring silhouette only.
        let axial_fade = smoothstep(h, h * 0.85, abs(y_back));
        contribution = axial_fade * 0.07;
    }

    return contribution;
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let res = u.resolution;
    var uv = (frag.xy - 0.5 * res) / res.y;
    uv.y = -uv.y;

    let t = u.time;

    // ---------- spiral vortex background ----------
    var p_bg = vec2<f32>(uv.x, uv.y / 0.7);
    let r_bg = length(p_bg);
    let th_bg = atan2(p_bg.y, p_bg.x);
    let arms = 5.0;
    let twist = 6.0;
    let phase = th_bg * arms - log(r_bg + 0.05) * twist + t * 0.35;
    var swirl = 0.5 + 0.5 * sin(phase);
    swirl = smoothstep(0.32, 0.68, swirl);
    let tunnel = smoothstep(0.0, 1.4, r_bg);
    var bg = mix(swirl * 0.10, swirl * 0.78, tunnel);
    let phase2 = -th_bg * (arms - 2.0) - log(r_bg + 0.05) * (twist * 0.6) - t * 0.18;
    let swirl2 = 0.5 + 0.5 * sin(phase2);
    bg = bg * (0.78 + 0.22 * swirl2);
    let shimmer = 0.5 + 0.5 * sin(t * 1.4 + uv.x * 9.0 + uv.y * 6.5);
    bg = bg + 0.04 * (shimmer - 0.5);
    let g_noise = hash21(uv * res * 0.5 + vec2<f32>(t * 60.0, t * 41.0));
    bg = bg + (g_noise - 0.5) * 0.07;
    var col = vec3<f32>(bg);

    // ---------- three large engraved rings ----------
    let R = 0.45;
    let h_band = 0.04;

    // Hours — top
    let cx_h = 0.00 + 0.04 * sin(t * 0.073) + 0.025 * cos(t * 0.131);
    let cy_h = 0.30 + 0.022 * sin(t * 0.091);
    let alpha_h = 0.25 + 0.04 * sin(t * 0.061);

    // Minutes — middle
    let cx_m = -0.03 + 0.05 * sin(t * 0.057) - 0.025 * cos(t * 0.119);
    let cy_m = 0.00 + 0.025 * sin(t * 0.063);
    let alpha_m = 0.27 + 0.04 * sin(t * 0.071);

    // Seconds — bottom
    let cx_s = 0.02 + 0.04 * sin(t * 0.103) + 0.03 * cos(t * 0.067);
    let cy_s = -0.30 + 0.022 * sin(t * 0.121);
    let alpha_s = 0.23 + 0.04 * sin(t * 0.083);

    // Ring rotations: ring_rot = π/2 − current_value × slot_pitch, so the
    // current digit sits at the front of the ring (phi = π/2).
    let r_h = PI * 0.5 - u.angles.x;
    let r_m = PI * 0.5 - u.angles.y;
    let r_s = PI * 0.5 - u.angles.z;

    let i_h = ring_brightness(uv, cx_h, cy_h, R, h_band, alpha_h, 12, r_h);
    let i_m = ring_brightness(uv, cx_m, cy_m, R, h_band, alpha_m, 60, r_m);
    let i_s = ring_brightness(uv, cx_s, cy_s, R, h_band, alpha_s, 60, r_s);
    col = col + vec3<f32>(i_h + i_m + i_s);

    // ---------- vignette + scanlines ----------
    let vig = smoothstep(1.05, 0.45, length(uv));
    col = col * vig;
    let scan = 0.94 + 0.06 * sin(frag.y * PI * 1.4);
    col = col * scan;

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(col, 1.0);
}
