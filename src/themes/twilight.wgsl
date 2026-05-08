// twilight.wgsl — Twilight Zone clock with three rotating digit rings.
//
// Each ring is a band of 7-segment digits riding on the dial; each ring
// rotates at the rate of its time unit (seconds: 1 rev / minute, minutes:
// 1 rev / hour, hours: 1 rev / 12 hours), so the digit at the top of the
// dial — the "highlight" — is always the current value. Numbers fade in
// and out as they approach and leave the highlight zone.
//
// Ring layout (inner → outer): hours, minutes, seconds. The seconds ring
// gets the largest circumference because it has 60 digits and turns the
// fastest, like a watch's sweep second hand on the rim.
//
// Screensaver-grade pixel motion comes from three concurrent drifts:
//   * Lissajous translation of the whole dial (~90 s period).
//   * Tilt oscillation: the perspective ellipse "rocks".
//   * Each ring's own rotation sweeps every pixel along its circumference.

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

fn ang_dist(a: f32, b: f32) -> f32 {
    let d = a - b;
    return abs(atan2(sin(d), cos(d)));
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
// Returns (sharp core | soft outer halo).
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

// Brightness contribution of one digit ring at the current pixel.
//
// `R`           — ring radius in dial-tilted coords.
// `scale`       — digit-local units per dial-coord unit (controls digit size).
// `n_slots`     — 12 for hours (display 1..12), 60 for minutes/seconds.
// `ring_rot`    — current angular rotation of this ring (radians).
// `highlight`   — angular position of the highlight zone (radians).
// `window`      — angular half-width of the highlight fade.
fn ring_brightness(
    r_pix: f32, theta_pix: f32,
    R: f32, scale: f32, n_slots: i32, ring_rot: f32,
    highlight: f32, window: f32,
) -> f32 {
    let radial_offset = r_pix - R;
    if (abs(radial_offset) > 0.07) { return 0.0; }

    let h_dist = ang_dist(theta_pix, highlight);
    let highlight_fade = smoothstep(window, window * 0.15, h_dist);

    // Local angle on the ring (which slot does this pixel fall into).
    let local_ang = theta_pix - ring_rot;
    let slot_pitch = TAU / f32(n_slots);
    let slot_idx_f = local_ang / slot_pitch;
    let slot_idx = i32(floor(slot_idx_f + 0.5));
    let slot_center = f32(slot_idx) * slot_pitch;
    let dtheta = local_ang - slot_center;

    var value = slot_idx % n_slots;
    if (value < 0) { value = value + n_slots; }

    // Map screen pixel into the slot's tangent/radial frame, then scale to
    // digit-local coords. The tangent axis runs CW so digit-local +x lines
    // up with screen +x at the top of the dial; otherwise digits would be
    // mirrored horizontally where the highlight sits.
    let arc_dist = -R * dtheta;
    let local = vec2<f32>(arc_dist, radial_offset) * scale;

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

    // Faint always-on ring trace + brighter band right at the highlight.
    let band = smoothstep(0.014, 0.0, abs(radial_offset));
    let band_dim = band * 0.05;
    let band_high = band * highlight_fade * 0.18;

    return d_int * highlight_fade * 0.95 + band_dim + band_high;
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let res = u.resolution;
    var uv0 = (frag.xy - 0.5 * res) / res.y;
    uv0.y = -uv0.y;

    let t = u.time;

    // ---------- screensaver drift: slow Lissajous translation ----------
    let drift = vec2<f32>(
        0.085 * sin(t * 0.053),
        0.055 * cos(t * 0.071)
    );
    let uv = uv0 - drift;

    // ---------- dial: oscillating perspective tilt ----------
    let tilt = 0.50 + 0.13 * sin(t * 0.041);
    let p = vec2<f32>(uv.x, uv.y / tilt);
    let r = length(p);
    let theta = atan2(p.y, p.x);

    // ---------- spiral vortex background (anchored to screen) ----------
    var p_bg = vec2<f32>(uv0.x, uv0.y / 0.7);
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
    let shimmer = 0.5 + 0.5 * sin(t * 1.4 + uv0.x * 9.0 + uv0.y * 6.5);
    bg = bg + 0.04 * (shimmer - 0.5);
    let g_noise = hash21(uv0 * res * 0.5 + vec2<f32>(t * 60.0, t * 41.0));
    bg = bg + (g_noise - 0.5) * 0.07;
    var col = vec3<f32>(bg);

    // ---------- three rotating digit rings ----------
    // Ring rotation: highlight − (current_value × slot_pitch). u.angles already
    // encodes current_value × slot_pitch for each unit.
    let highlight = PI * 0.5;        // top of the dial
    let win = 0.42;                  // visibility cone (radians half-width)
    let r_h = highlight - u.angles.x;  // 1 revolution / 12 hours
    let r_m = highlight - u.angles.y;  // 1 revolution / hour
    let r_s = highlight - u.angles.z;  // 1 revolution / minute

    let i_h = ring_brightness(r, theta, 0.18, 50.0, 12, r_h, highlight, win);
    let i_m = ring_brightness(r, theta, 0.32, 80.0, 60, r_m, highlight, win);
    let i_s = ring_brightness(r, theta, 0.46, 80.0, 60, r_s, highlight, win);
    col = col + vec3<f32>(i_h + i_m + i_s);

    // ---------- vignette + scanlines ----------
    let vig = smoothstep(1.05, 0.45, length(uv));
    col = col * vig;
    let scan = 0.94 + 0.06 * sin(frag.y * PI * 1.4);
    col = col * scan;

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(col, 1.0);
}
