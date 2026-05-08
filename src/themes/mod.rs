pub const AVAILABLE: &[&str] = &["twilight"];

pub fn shader_for(name: &str) -> &'static str {
    match name {
        "twilight" => include_str!("twilight.wgsl"),
        _ => include_str!("twilight.wgsl"),
    }
}
