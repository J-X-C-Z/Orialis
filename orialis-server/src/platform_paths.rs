//! Constrained filesystem paths for platform adapters.
//!
//! This module deliberately is not wired into HTTP routes. Callers must choose
//! an explicit storage root and still apply OS ownership/permissions to it.

use std::{
    fs, io,
    path::{Component, Path, PathBuf},
};

#[derive(Debug)]
pub struct RootedPaths {
    root: PathBuf,
}

impl RootedPaths {
    /// Create or open a storage root and retain its canonical path.
    pub fn new(root: impl AsRef<Path>) -> io::Result<Self> {
        fs::create_dir_all(root.as_ref())?;
        let root = fs::canonicalize(root)?;
        if !root.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "root is not a directory",
            ));
        }
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Resolve an existing file/directory, rejecting absolute paths, traversal,
    /// and symlinks whose canonical target leaves the configured root.
    pub fn existing(&self, relative: impl AsRef<Path>) -> io::Result<PathBuf> {
        let candidate = self.candidate(relative.as_ref())?;
        let resolved = fs::canonicalize(candidate)?;
        self.ensure_contained(&resolved)?;
        Ok(resolved)
    }

    /// Resolve a new leaf under an existing parent. The leaf must not already
    /// exist; callers should create it with create_new to avoid following a
    /// pre-existing symlink. This check alone is not an atomic open operation.
    pub fn new_file(&self, relative: impl AsRef<Path>) -> io::Result<PathBuf> {
        let candidate = self.candidate(relative.as_ref())?;
        let parent = candidate.parent().ok_or_else(invalid_path)?;
        let resolved_parent = fs::canonicalize(parent)?;
        self.ensure_contained(&resolved_parent)?;
        if candidate.exists() || fs::symlink_metadata(&candidate).is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "target already exists",
            ));
        }
        Ok(resolved_parent.join(candidate.file_name().ok_or_else(invalid_path)?))
    }

    fn candidate(&self, relative: &Path) -> io::Result<PathBuf> {
        if relative.as_os_str().is_empty()
            || relative
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Err(invalid_path());
        }
        Ok(self.root.join(relative))
    }

    fn ensure_contained(&self, path: &Path) -> io::Result<()> {
        if path.starts_with(&self.root) {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "path escapes configured root",
            ))
        }
    }
}

fn invalid_path() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "path must be relative and contain only normal components",
    )
}

#[cfg(test)]
mod tests {
    use super::RootedPaths;
    use std::{
        fs, io,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "orialis-platform-paths-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn rejects_traversal_and_absolute_paths() {
        let temp = Temp::new();
        let paths = RootedPaths::new(temp.0.join("root")).unwrap();
        assert_eq!(
            paths.existing("../outside").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            paths.new_file("/tmp/outside").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn rejects_symlink_escape_for_reads_and_new_file_parent() {
        let temp = Temp::new();
        let root = temp.0.join("root");
        let outside = temp.0.join("outside");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("secret"), b"secret").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        let paths = RootedPaths::new(&root).unwrap();
        #[cfg(unix)]
        {
            assert!(paths.existing("link/secret").is_err());
            assert!(paths.new_file("link/new").is_err());
        }
    }

    #[test]
    fn accepts_in_root_paths_and_only_new_leaf_targets() {
        let temp = Temp::new();
        let root = temp.0.join("root");
        fs::create_dir_all(root.join("nested")).unwrap();
        fs::write(root.join("nested/existing"), b"ok").unwrap();
        let paths = RootedPaths::new(&root).unwrap();
        assert_eq!(
            paths.existing("nested/existing").unwrap(),
            fs::canonicalize(root.join("nested/existing")).unwrap()
        );
        assert_eq!(
            paths.new_file("nested/new").unwrap(),
            fs::canonicalize(root.join("nested")).unwrap().join("new")
        );
        assert!(root.join("nested/existing").exists());
        assert_eq!(
            paths.new_file("nested/existing").unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
    }
}
