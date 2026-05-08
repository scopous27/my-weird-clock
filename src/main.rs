mod render;
mod themes;

use std::sync::Arc;
use winit::application::ApplicationHandler;
use winit::event::{ElementState, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Fullscreen, Window, WindowId};

struct App {
    theme: String,
    state: Option<render::State>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.state.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title("weird-clock")
            .with_decorations(false)
            .with_fullscreen(Some(Fullscreen::Borderless(None)));
        let window = Arc::new(event_loop.create_window(attrs).expect("create window"));
        window.set_cursor_visible(false);
        let state = pollster::block_on(render::State::new(window.clone(), &self.theme));
        self.state = Some(state);
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _id: WindowId,
        event: WindowEvent,
    ) {
        let Some(state) = self.state.as_mut() else { return };
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::KeyboardInput { event: ke, .. } => {
                if ke.state == ElementState::Pressed {
                    let quit = matches!(ke.logical_key, Key::Named(NamedKey::Escape))
                        || matches!(&ke.logical_key, Key::Character(c) if c.eq_ignore_ascii_case("q"));
                    if quit {
                        event_loop.exit();
                    }
                }
            }
            WindowEvent::Resized(size) => state.resize(size),
            WindowEvent::RedrawRequested => state.render(),
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(state) = self.state.as_ref() {
            state.window().request_redraw();
        }
    }
}

fn parse_theme(args: impl IntoIterator<Item = String>) -> String {
    let mut iter = args.into_iter().skip(1);
    while let Some(a) = iter.next() {
        if a == "--theme" || a == "-t" {
            if let Some(v) = iter.next() {
                return v;
            }
        } else if let Some(v) = a.strip_prefix("--theme=") {
            return v.to_string();
        } else if a == "--list" {
            for t in themes::AVAILABLE {
                println!("{t}");
            }
            std::process::exit(0);
        } else if a == "--help" || a == "-h" {
            print_help();
            std::process::exit(0);
        }
    }
    "twilight".to_string()
}

fn print_help() {
    println!(
        "weird-clock — a 3D rotating-band screensaver clock\n\
         \n\
         USAGE:\n    weird-clock [--theme <name>]\n\
         \n\
         OPTIONS:\n    -t, --theme <name>   Pick a theme (default: twilight)\n        --list           List available themes\n    -h, --help           Print help\n\
         \n\
         Press Esc or Q to quit."
    );
}

fn main() {
    let theme = parse_theme(std::env::args().collect::<Vec<_>>());
    if !themes::AVAILABLE.contains(&theme.as_str()) {
        eprintln!(
            "unknown theme '{theme}'. available: {}",
            themes::AVAILABLE.join(", ")
        );
        std::process::exit(2);
    }
    let event_loop = EventLoop::new().expect("event loop");
    event_loop.set_control_flow(winit::event_loop::ControlFlow::Poll);
    let mut app = App { theme, state: None };
    event_loop.run_app(&mut app).expect("run");
}
