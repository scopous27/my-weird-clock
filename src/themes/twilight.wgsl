// twilight.wgsl — Twilight Zone inspired clock.
// Three concentric tilted rings (hours / minutes / seconds) with glowing
// marker arcs over a counter-rotating B&W log-polar spiral vortex, and a
// 7-segment digital HH:MM:SS readout below the dial.
//
// As a screensaver, the entire scene drifts so no single pixel stays lit:
//   * Lissajous translation moves the dial + readout + vignette.
//   * Tilt oscillation rocks the perspective ellipse.
//   * Slow rotation of the dial sweeps marker arcs across all ring pixels.
//   * Background vortex spirals are time-driven so each pixel pulses.

struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    _pad: f32,
    angles: vec4<f32>,    // x = hour, y = minute, z = second (radians)
    time_hms: vec4<f32>,  // x = h_disp (1..12), y = minute, z = second
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

// SDF for an axis-aligned box at center `c`, half-extents `b`.
fn sdf_box(p: vec2<f32>, c: vec2<f32>, b: vec2<f32>) -> f32 {
    let q = abs(p - c) - b;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0);
}

// 7-segment mask. bits: a=top, b=top-right, c=bottom-right, d=bottom,
// e=bottom-left, f=top-left, g=middle.
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

// Render a 7-segment digit centered at origin.
// Cell occupies x in [-0.5, 0.5], y in [-1.0, 1.0].
fn digit(p: vec2<f32>, value: i32) -> f32 {
    let m = seg_mask(value);
    let bh = vec2<f32>(0.42, 0.07);  // horizontal segment box half-extents
    let bv = vec2<f32>(0.07, 0.42);  // vertical segment box half-extents
    var d = 1e9;
    if ((m & 0x01u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.0,  1.0), bh)); }
    if ((m & 0x02u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.5,  0.5), bv)); }
    if ((m & 0x04u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.5, -0.5), bv)); }
    if ((m & 0x08u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.0, -1.0), bh)); }
    if ((m & 0x10u) != 0u) { d = min(d, sdf_box(p, vec2<f32>(-0.5, -0.5), bv)); }
    if ((m & 0x20u) != 0u) { d = min(d, sdf_box(p, vec2<f32>(-0.5,  0.5), bv)); }
    if ((m & 0x40u) != 0u) { d = min(d, sdf_box(p, vec2<f32>( 0.0,  0.0), bh)); }
    return smoothstep(0.025, 0.0, d);
}

fn colon_glyph(p: vec2<f32>) -> f32 {
    let d1 = length(p - vec2<f32>(0.0,  0.45)) - 0.10;
    let d2 = length(p - vec2<f32>(0.0, -0.45)) - 0.10;
    return smoothstep(0.025, 0.0, min(d1, d2));
}

// Render HH:MM:SS in digit-local coords (one digit cell ~ 1 unit wide, 2 tall).
fn readout(p: vec2<f32>, h: i32, mn: i32, sc: i32) -> f32 {
    var v = 0.0;
    v = max(v, digit(p - vec2<f32>(-3.6, 0.0), (h  / 10) % 10));
    v = max(v, digit(p - vec2<f32>(-2.4, 0.0),  h        % 10));
    v = max(v, colon_glyph(p - vec2<f32>(-1.5, 0.0)));
    v = max(v, digit(p - vec2<f32>(-0.6, 0.0), (mn / 10) % 10));
    v = max(v, digit(p - vec2<f32>( 0.6, 0.0),  mn       % 10));
    v = max(v, colon_glyph(p - vec2<f32>( 1.5, 0.0)));
    v = max(v, digit(p - vec2<f32>( 2.4, 0.0), (sc / 10) % 10));
    v = max(v, digit(p - vec2<f32>( 3.6, 0.0),  sc       % 10));
    return v;
}

fn ring(
    base: vec3<f32>,
    r: f32,
    theta: f32,
    radius: f32,
    thick: f32,
    marker_ang: f32,
    arc: f32,
) -> vec3<f32> {
    let d = abs(r - radius);
    let body = smoothstep(thick, thick * 0.4, d);
    let glow = smoothstep(thick * 4.0, 0.0, d);
    let ad = ang_dist(theta, marker_ang);
    let marker = smoothstep(arc, arc * 0.25, ad);
    // Dim base (so ring pixels aren't always bright) + bright marker glow.
    let body_lum = body * 0.18;
    let marker_lum = (body * 1.0 + glow * 0.55) * marker;
    return base + vec3<f32>(body_lum + marker_lum);
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

    // ---------- dial: oscillating tilt + slow rotation ----------
    let tilt = 0.50 + 0.13 * sin(t * 0.041);
    var p = vec2<f32>(uv.x, uv.y / tilt);
    let dial_rot = t * 0.006;  // ~17.5 minutes per full revolution
    let cs = cos(dial_rot);
    let sn = sin(dial_rot);
    p = vec2<f32>(cs * p.x - sn * p.y, sn * p.x + cs * p.y);
    let r = length(p);
    let theta = atan2(p.y, p.x);

    // ---------- spiral vortex background (anchored in screen space) ----------
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

    // ---------- the three rings (markers ride on the rotating dial) ----------
    let h_marker = -u.angles.x + PI * 0.5;
    let m_marker = -u.angles.y + PI * 0.5;
    let s_marker = -u.angles.z + PI * 0.5;

    col = ring(col, r, theta, 0.42, 0.014, h_marker, 0.32);
    col = ring(col, r, theta, 0.32, 0.012, m_marker, 0.22);
    col = ring(col, r, theta, 0.22, 0.009, s_marker, 0.12);

    // ---------- digital readout (drifts with dial) ----------
    let readout_scale = 22.0;
    let readout_pos = vec2<f32>(0.0, -0.40);
    let r_local = (uv - readout_pos) * readout_scale;
    let h_int = i32(u.time_hms.x);
    let m_int = i32(u.time_hms.y);
    let s_int = i32(u.time_hms.z);
    let r_intensity = readout(r_local, h_int, m_int, s_int);
    // Breathing brightness so digit pixels don't sit at peak.
    let breath = 0.65 + 0.35 * (0.5 + 0.5 * sin(t * 0.6));
    col = col + vec3<f32>(r_intensity * breath * 0.85);

    // ---------- vignette (centered on the drifted dial) + scanlines ----------
    let vig = smoothstep(1.05, 0.45, length(uv));
    col = col * vig;
    let scan = 0.94 + 0.06 * sin(frag.y * PI * 1.4);
    col = col * scan;

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(col, 1.0);
}
