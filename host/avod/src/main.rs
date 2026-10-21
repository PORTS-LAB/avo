//! The `avod` binary: the daemon's entry point. Flags in, the body's exit
//! code out — nothing else; the body is the whole process (src/body.rs),
//! and the packaging's unit runs this binary flag-less against its
//! defaults (dist/avod.service).

fn main() {
    let config = match avod::body::cli(std::env::args().collect()) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("avod: {message}");
            std::process::exit(1);
        }
    };
    let code = avod::body::running(config, None);
    std::process::exit(code);
}
