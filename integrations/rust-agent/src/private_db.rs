//! Private SQLite storage on Unix. Never repairs permissions on existing paths.
//! Assumes other processes running as this UID are trusted. SQLite reopens by
//! pathname, so this is not a defense against a malicious same-UID process.
use anyhow::{Result, ensure};
use rusqlite::Connection;
use std::path::Path;

pub fn open_private(path: &Path) -> Result<Connection> {
    if path == Path::new(":memory:") {
        return Ok(Connection::open_in_memory()?);
    }
    #[cfg(unix)]
    {
        unix::open(path)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        anyhow::bail!(
            "private disk databases require Unix permission checks; Windows ACL support is not implemented"
        )
    }
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::{
        fs::{self, Metadata, OpenOptions},
        os::unix::fs::{MetadataExt, OpenOptionsExt},
        path::{Component, PathBuf},
        sync::Mutex,
    };

    // Only serializes initial file creation through sqlite3_open, never a SQL
    // statement or busy wait. A second local opener must not acquire SQLite
    // locks before the creator closes its one temporary creation descriptor.
    static OPENING: Mutex<()> = Mutex::new(());

    fn uid() -> u32 {
        unsafe { libc::geteuid() }
    }

    fn file_safe(meta: &Metadata) -> Result<()> {
        ensure!(
            meta.is_file() && !meta.file_type().is_symlink(),
            "database path must be a regular file"
        );
        ensure!(
            meta.uid() == uid() && meta.nlink() == 1 && meta.mode() & 0o777 == 0o600,
            "database file must be owned by current user, single-linked, and mode 0600"
        );
        Ok(())
    }

    fn check_optional_file(path: &Path) -> Result<()> {
        match fs::symlink_metadata(path) {
            Ok(meta) => file_safe(&meta),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    fn checked_path(path: &Path) -> Result<PathBuf> {
        ensure!(!path.as_os_str().is_empty(), "empty database path");
        // Never normalize through a symlink or allow '..' to bypass checks.
        ensure!(
            !path.components().any(|c| matches!(c, Component::ParentDir)),
            "database path cannot contain parent traversal"
        );
        let path = if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()?.join(path)
        };
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("missing database directory"))?;
        for ancestor in parent.ancestors() {
            let meta = fs::symlink_metadata(ancestor)?;
            ensure!(
                meta.is_dir() && !meta.file_type().is_symlink(),
                "database ancestors must be real directories"
            );
            ensure!(
                meta.uid() == uid() || meta.uid() == 0,
                "database ancestors must be owned by current user or root"
            );
            let writable_by_others = meta.mode() & 0o022 != 0;
            // Root-owned sticky /tmp is acceptable as an ancestor, never as the
            // immediate directory containing SQLite files.
            let trusted_sticky_ancestor =
                ancestor != parent && meta.uid() == 0 && meta.mode() & 0o1000 != 0;
            ensure!(
                !writable_by_others || trusted_sticky_ancestor,
                "database directory is writable by other users"
            );
        }
        Ok(path)
    }

    fn sidecar(path: &Path, suffix: &str) -> PathBuf {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        name.into()
    }

    pub fn open(path: &Path) -> Result<Connection> {
        let path = checked_path(path)?;
        check_optional_file(&path)?;
        for suffix in ["-wal", "-shm", "-journal"] {
            check_optional_file(&sidecar(&path, suffix))?;
        }
        let (conn, original) = {
            let _opening = OPENING
                .lock()
                .map_err(|_| anyhow::anyhow!("private database opening lock poisoned"))?;
            // Atomic creation makes a new database private before SQLite can
            // write. Close this descriptor before the first SQLite open. Never
            // open an ordinary descriptor for an existing database: closing it
            // would drop this process's POSIX locks held by other connections,
            // outside SQLite's deferred-close bookkeeping (howtocorrupt §2.2).
            let original = match OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&path)
            {
                Ok(file) => {
                    let metadata = file.metadata()?;
                    drop(file);
                    metadata
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    fs::symlink_metadata(&path)?
                }
                Err(e) => return Err(e.into()),
            };
            file_safe(&original)?;
            let conn = Connection::open_with_flags(
                &path,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
                    | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
                    | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
            )?;
            (conn, original)
        };
        let now = fs::symlink_metadata(&path)?;
        ensure!(
            now.dev() == original.dev() && now.ino() == original.ino(),
            "database path changed while opening"
        );
        file_safe(&now)?;
        // SQLite's Unix VFS derives WAL/SHM/journal permissions from the main
        // file. Verify the resulting files too. No chmod is performed anywhere.
        let mode: String = conn.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
        ensure!(
            mode.eq_ignore_ascii_case("wal"),
            "private database could not enable WAL"
        );
        for suffix in ["-wal", "-shm", "-journal"] {
            check_optional_file(&sidecar(&path, suffix))?;
        }
        Ok(conn)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn in_memory_works() {
        open_private(Path::new(":memory:"))
            .unwrap()
            .execute_batch("CREATE TABLE test (id INTEGER)")
            .unwrap();
    }
    #[cfg(unix)]
    mod permissions {
        use super::*;
        use std::{
            fs,
            os::unix::fs::{MetadataExt, PermissionsExt, symlink},
        };
        fn temp() -> tempfile::TempDir {
            let dir = tempfile::tempdir().unwrap();
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
            dir
        }
        #[test]
        fn main_wal_and_shm_are_private_and_reopen() {
            let dir = temp();
            let path = dir.path().join("private.sqlite");
            let conn = open_private(&path).unwrap();
            conn.execute_batch("CREATE TABLE test (id INTEGER); INSERT INTO test VALUES (1)")
                .unwrap();
            for suffix in ["", "-wal", "-shm"] {
                let file = dir.path().join(format!("private.sqlite{suffix}"));
                let metadata = fs::symlink_metadata(file).unwrap();
                assert_eq!(metadata.mode() & 0o777, 0o600);
            }
            assert_eq!(
                open_private(&path)
                    .unwrap()
                    .query_row("SELECT id FROM test", [], |r| r.get::<_, i64>(0))
                    .unwrap(),
                1
            );
        }
        #[test]
        fn unsafe_existing_file_and_sidecars_rejected_without_changes() {
            let dir = temp();
            let path = dir.path().join("private.sqlite");
            fs::write(&path, b"unchanged").unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            assert!(open_private(&path).is_err());
            assert_eq!(fs::read(&path).unwrap(), b"unchanged");
            assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o644);
            fs::remove_file(&path).unwrap();
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecar = dir.path().join(format!("private.sqlite{suffix}"));
                fs::write(&sidecar, b"unchanged").unwrap();
                fs::set_permissions(&sidecar, fs::Permissions::from_mode(0o644)).unwrap();
                assert!(open_private(&path).is_err());
                assert!(!path.exists());
                assert_eq!(fs::read(&sidecar).unwrap(), b"unchanged");
                fs::remove_file(sidecar).unwrap();
            }
        }
        #[test]
        fn symlink_and_hardlink_rejected() {
            let dir = temp();
            let target = dir.path().join("target");
            fs::write(&target, b"original").unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
            let path = dir.path().join("alias");
            symlink(&target, &path).unwrap();
            assert!(open_private(&path).is_err());
            fs::remove_file(&path).unwrap();
            fs::hard_link(&target, &path).unwrap();
            assert!(open_private(&path).is_err());
            assert_eq!(fs::read(&target).unwrap(), b"original");
            let alias_dir = dir.path().join("linked-dir");
            symlink(dir.path(), &alias_dir).unwrap();
            assert!(open_private(&alias_dir.join("new.sqlite")).is_err());
        }
        #[test]
        fn unsafe_directory_and_parent_traversal_rejected() {
            let dir = temp();
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o777)).unwrap();
            assert!(open_private(&dir.path().join("new.sqlite")).is_err());
            assert!(open_private(&dir.path().join("../new.sqlite")).is_err());
        }
    }
}
