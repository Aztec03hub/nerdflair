// Embeds a fingerprint of the sources this binary was built from, so
// `nerdflair-statusline --version` (and `nerdflair doctor`) can tell a stale
// installed copy from this checkout's build. scripts/doctor.sh computes the same
// hash the same way: src/*.rs in byte order, then Cargo.toml, then Cargo.lock,
// concatenated and fed to sha256sum, first 8 hex.
use std::io::Write;
use std::process::{Command, Stdio};

fn main() {
    let mut files: Vec<std::path::PathBuf> = std::fs::read_dir("src")
        .expect("build.rs: read src/")
        .map(|e| e.expect("build.rs: read src/ entry").path())
        .filter(|p| p.extension().map_or(false, |x| x == "rs"))
        .collect();
    files.sort();
    files.push("Cargo.toml".into());
    files.push("Cargo.lock".into());
    let mut raw = Vec::new();
    for f in &files {
        raw.extend(std::fs::read(f).unwrap_or_else(|e| panic!("build.rs: read {}: {}", f.display(), e)));
    }
    // ponytail: shells out to coreutils sha256sum instead of vendoring a sha256; a crate is the upgrade if a build host lacks it
    let mut child = Command::new("sha256sum")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("build.rs: sha256sum is needed to stamp the build (coreutils)");
    child.stdin.take().unwrap().write_all(&raw).expect("build.rs: write to sha256sum");
    let out = child.wait_with_output().expect("build.rs: sha256sum");
    assert!(out.status.success(), "build.rs: sha256sum failed");
    let hex = String::from_utf8_lossy(&out.stdout);
    println!("cargo:rustc-env=NF_SRC_HASH={}", &hex[..8]);
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=Cargo.lock");
}
