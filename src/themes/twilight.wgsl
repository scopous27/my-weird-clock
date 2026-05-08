// twilight.wgsl — Twilight Zone inspired clock.
// Black & white spiral vortex background; three concentric rings (hour / minute /
// second) tilted into a perspective ellipse, each with a glowing marker arc.

struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    _pad: f32,
    angles: vec4<f32>,   // x = hour, y = minute, z = second, w = unused
};

@group(0) @binding(0) var<uniform> u: Uniforms;

const PI: f32 = 3.14159265358979;
const TAU: f32 = 6.28318530717958;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    // Single oversized triangle covering the screen.
    let x = f32((vi << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(vi & 2u) * 2.0 - 1.0;
    return vec4<f32>(x, y, 0.0, 1.0);
}

fn hash21(p: vec2<f32>) -> f32 {
    let h = dot(p, vec2<f32>(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

// Smooth boxy band around `target` with falloff `width`.
fn band(d: f32, width: f32) -> f32 {
    return smoothstep(width, width * 0.4, d);
}

// Returns wrapped angular distance in [0, PI].
fn ang_dist(a: f32, b: f32) -> f32 {
    let d = a - b;
    return abs(atan2(sin(d), cos(d)));
}

struct RingOut { col: vec3<f32>, lum: f32 };

fn ring(
    base: vec3<f32>,
    base_lum: f32,
    r: f32,
    theta: f32,
    radius: f32,
    thick: f32,
    marker_ang: f32,
    arc: f32,
) -> RingOut {
    let d = abs(r - radius);
    let body = band(d, thick);                 // 0..1 along the ring
    let glow = smoothstep(thick * 4.0, 0.0, d);// soft halo

    // Marker: bright arc that points to the current value.
    let ad = ang_dist(theta, marker_ang);
    let marker = smoothstep(arc, arc * 0.25, ad);

    // Dim background ring + bright marker segment.
    let body_lum = body * 0.55;
    let marker_lum = (body * 1.0 + glow * 0.55) * marker;
    let added = body_lum * 0.5 + marker_lum;

    var out: RingOut;
    out.col = base + vec3<f32>(added);
    out.lum = base_lum + added;
    return out;
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let res = u.resolution;
    // Aspect-correct, centered, y-up.
    var uv = (frag.xy - 0.5 * res) / res.y;
    uv.y = -uv.y;

    // Tilt the dial: squash y to fake a record-on-a-turntable perspective.
    let tilt = 0.55;
    let p = vec2<f32>(uv.x, uv.y / tilt);
    let r = length(p);
    let theta = atan2(p.y, p.x);

    let t = u.time;

    // ---------- spiral vortex background ----------
    // Log-polar spiral: angle + log(radius) creates the iconic Twilight-Zone swirl.
    let arms = 5.0;
    let twist = 6.0;
    let phase = theta * arms - log(r + 0.05) * twist + t * 0.35;
    var swirl = 0.5 + 0.5 * sin(phase);
    swirl = smoothstep(0.32, 0.68, swirl);

    // Pull the swirl into a tunnel: dim near the center, brighter further out.
    let tunnel = smoothstep(0.0, 1.4, r);
    var bg = mix(swirl * 0.10, swirl * 0.82, tunnel);

    // A second, slower-counter-rotating spiral — adds subtle interference.
    let phase2 = -theta * (arms - 2.0) - log(r + 0.05) * (twist * 0.6) - t * 0.18;
    let swirl2 = 0.5 + 0.5 * sin(phase2);
    bg = bg * (0.78 + 0.22 * swirl2);

    // Shimmer + film grain.
    let shimmer = 0.5 + 0.5 * sin(t * 1.4 + uv.x * 9.0 + uv.y * 6.5);
    bg = bg + 0.04 * (shimmer - 0.5);
    let g = hash21(uv * res * 0.5 + vec2<f32>(t * 60.0, t * 41.0));
    bg = bg + (g - 0.5) * 0.07;

    var col = vec3<f32>(bg);
    var lum = bg;

    // ---------- the three rings ----------
    // Marker angles: subtract PI/2 so 12 o'clock is straight up.
    let h_ang = -u.angles.x + PI * 0.5;
    let m_ang = -u.angles.y + PI * 0.5;
    let s_ang = -u.angles.z + PI * 0.5;

    // Outer-to-inner: hours (largest), minutes, seconds.
    let r_h = 0.40;
    let r_m = 0.30;
    let r_s = 0.20;

    let o1 = ring(col, lum, r, theta, r_h, 0.014, h_ang, 0.32);
    col = o1.col; lum = o1.lum;
    let o2 = ring(col, lum, r, theta, r_m, 0.012, m_ang, 0.22);
    col = o2.col; lum = o2.lum;
    let o3 = ring(col, lum, r, theta, r_s, 0.009, s_ang, 0.12);
    col = o3.col; lum = o3.lum;

    // Tiny dot at the center of the dial.
    let center = smoothstep(0.014, 0.006, r);
    col = col + vec3<f32>(center * 0.9);

    // ---------- vignette + slight desaturation ----------
    let dscreen = length(uv);
    let vig = smoothstep(0.95, 0.30, dscreen);
    col = col * vig;

    // Subtle scanline / CRT feel.
    let scan = 0.95 + 0.05 * sin(frag.y * 3.14159 * 1.2);
    col = col * scan;

    // Clamp; shader output is treated as linear and gamma-encoded by the sRGB surface.
    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(col, 1.0);
}
