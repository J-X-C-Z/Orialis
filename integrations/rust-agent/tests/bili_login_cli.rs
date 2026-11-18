//! Binary subprocess checks never begin a real external account login.
#![cfg(unix)]
use sha2::{Digest, Sha256};
use std::{fs, os::unix::fs::PermissionsExt, process::Command};
#[test]
fn binary_requires_explicit_paths_and_inactive_status_is_read_only() {
    let binary = env!("CARGO_BIN_EXE_bili_login");
    assert!(
        !Command::new(binary)
            .env_clear()
            .output()
            .unwrap()
            .status
            .success()
    );
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missing/account.json");
    for op in ["status", "cancel"] {
        let out = Command::new(binary)
            .env_clear()
            .arg("--credential-file")
            .arg(&path)
            .arg(op)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let state: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(state["state"], "inactive");
        assert!(!path.parent().unwrap().exists());
    }
}
#[test]
fn binary_startup_ipc_failure_preserves_credentials_and_never_creates_qr() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("credentials.json");
    let qr = dir.path().join("qr.png");
    fs::write(&path, b"PRESERVED_SYNTHETIC_SESSION").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let digest = Sha256::digest(path.as_os_str().as_encoded_bytes());
    let suffix: String = digest[..10].iter().map(|b| format!("{b:02x}")).collect();
    let control = dir.path().join(format!(".bili-login-{suffix}"));
    fs::create_dir(&control).unwrap();
    fs::set_permissions(&control, fs::Permissions::from_mode(0o700)).unwrap();
    // A conflicting regular file forces a safe pre-network failure on any host.
    fs::write(control.join("control.sock"), b"not a socket").unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_bili_login"))
        .env_clear()
        .arg("--credential-file")
        .arg(&path)
        .arg("start")
        .arg("--qr-file")
        .arg(&qr)
        .arg("--timeout")
        .arg("15")
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("No QR was requested"));
    assert!(!String::from_utf8_lossy(&out.stderr).contains("PRESERVED_SYNTHETIC_SESSION"));
    assert_eq!(fs::read(&path).unwrap(), b"PRESERVED_SYNTHETIC_SESSION");
    assert!(!qr.exists());
}
