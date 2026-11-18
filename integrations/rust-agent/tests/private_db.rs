#![cfg(unix)]
use anyhow::Result;
use hermes_rust_core::private_db;
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::Path,
    process::Command,
};

fn assert_sqlite_shared_lock_is_held(path: &Path) -> Result<()> {
    // SQLite's Unix SHARED lock covers these bytes in the main database even
    // in WAL mode. Probe from another process, since POSIX locks are per-process.
    let output = Command::new("python3")
        .args([
            "-c",
            r#"
import errno, fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 510, 0x40000002, os.SEEK_SET)
except OSError as error:
    if error.errno not in (errno.EAGAIN, errno.EACCES):
        raise
else:
    raise AssertionError('live SQLite connection lost its process-level shared lock')
finally:
    os.close(fd)
"#,
        ])
        .arg(path)
        .output()?;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(())
}

#[test]
fn creation_and_reopening_preserve_live_sqlite_process_locks() -> Result<()> {
    let root = tempfile::tempdir()?;
    let path = root.path().join("private.sqlite");
    let first = private_db::open_private(&path)?;
    first
        .execute_batch("CREATE TABLE records(value TEXT); INSERT INTO records VALUES('before')")?;
    assert_sqlite_shared_lock_is_held(&path)?;
    for _ in 0..3 {
        let second = private_db::open_private(&path)?;
        // Probe before any additional SQL can happen to reacquire a lost lock.
        assert_sqlite_shared_lock_is_held(&path)?;
        assert_eq!(
            second.query_row("SELECT value FROM records", [], |row| row
                .get::<_, String>(0))?,
            "before"
        );
        drop(second);
        assert_sqlite_shared_lock_is_held(&path)?;
    }
    first.execute("UPDATE records SET value='after'", [])?;
    let output = Command::new("python3")
        .args(["-c", "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); assert c.execute('SELECT value FROM records').fetchone()[0]=='after'; c.close()"])
        .arg(&path).output()?;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_sqlite_shared_lock_is_held(&path)?;
    Ok(())
}

#[test]
fn private_open_keeps_permission_and_link_checks_fail_closed() -> Result<()> {
    let root = tempfile::tempdir()?;
    let path = root.path().join("private.sqlite");
    drop(private_db::open_private(&path)?);
    assert_eq!(fs::metadata(&path)?.permissions().mode() & 0o777, 0o600);
    let linked = root.path().join("symlink.sqlite");
    symlink(&path, &linked)?;
    assert!(private_db::open_private(&linked).is_err());
    let hard = root.path().join("hardlink.sqlite");
    fs::hard_link(&path, &hard)?;
    assert!(private_db::open_private(&hard).is_err());
    fs::remove_file(hard)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644))?;
    assert!(private_db::open_private(&path).is_err());
    assert_eq!(fs::metadata(&path)?.permissions().mode() & 0o777, 0o644);
    Ok(())
}

#[test]
fn unsafe_companions_and_parent_are_rejected_without_repairs() -> Result<()> {
    let root = tempfile::tempdir()?;
    let path = root.path().join("private.sqlite");
    drop(private_db::open_private(&path)?);
    let companion = root.path().join("private.sqlite-wal");
    fs::write(&companion, b"private sentinel")?;
    fs::set_permissions(&companion, fs::Permissions::from_mode(0o644))?;
    assert!(private_db::open_private(&path).is_err());
    assert_eq!(fs::read(&companion)?, b"private sentinel");
    fs::remove_file(companion)?;
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o777))?;
    assert!(private_db::open_private(&path).is_err());
    assert_eq!(
        fs::metadata(root.path())?.permissions().mode() & 0o777,
        0o777
    );
    Ok(())
}
