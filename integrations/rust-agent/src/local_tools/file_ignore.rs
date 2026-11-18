//! Bounded ignore rules loaded only through the configured descriptor root.
//! No .git metadata, parent-of-root files, user configuration or subprocesses.
use super::super::{ProtectedRoot, Result, ensure, snapshot};
use anyhow::Context;
use std::{ffi::CString, os::fd::AsRawFd};

const MAX_BYTES: usize = 256 * 1024;
const MAX_FILE_BYTES: usize = 64 * 1024;
const MAX_RULES: usize = 4096;
struct Rule {
    base: String,
    expression: regex::Regex,
    directory_only: bool,
    whitelist: bool,
}
#[derive(Default)]
pub(super) struct Rules {
    git: Vec<Rule>,
    plain: Vec<Rule>,
    bytes: usize,
    count: usize,
    pub files: usize,
}
impl Rules {
    pub fn checkpoint(&self) -> (usize, usize) {
        (self.git.len(), self.plain.len())
    }
    pub fn restore(&mut self, at: (usize, usize)) {
        self.git.truncate(at.0);
        self.plain.truncate(at.1);
    }
    pub fn load(&mut self, root: &ProtectedRoot, directory: &str, file_bytes: usize) -> Result<()> {
        let dir = root.open_dir(directory)?;
        for (name, plain) in [(".gitignore", false), (".ignore", true)] {
            // Listing deliberately omits links and special files. Inspect only these
            // two known basenames without following them, so an unsafe rule source
            // fails closed instead of silently disabling exclusions.
            let name_c = CString::new(name)?;
            let mut meta = std::mem::MaybeUninit::<libc::stat>::uninit();
            let rc = unsafe {
                libc::fstatat(
                    dir.as_raw_fd(),
                    name_c.as_ptr(),
                    meta.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            };
            if rc != 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::NotFound {
                    continue;
                }
                return Err(error).context("could not inspect ignore rules");
            }
            let meta = unsafe { meta.assume_init() };
            ensure!(
                meta.st_mode & libc::S_IFMT == libc::S_IFREG && meta.st_nlink == 1,
                "ignore rule source must be regular and not linked"
            );
            let path = if directory.is_empty() {
                name.to_owned()
            } else {
                format!("{directory}/{name}")
            };
            let (bytes, _) = snapshot(root, &path, file_bytes.min(MAX_FILE_BYTES))
                .context("could not safely read ignore rules")?;
            self.bytes += bytes.len();
            self.files += 1;
            ensure!(
                self.bytes <= MAX_BYTES,
                "ignore rule total byte bound reached"
            );
            let text = std::str::from_utf8(&bytes).context("ignore rules must be UTF-8")?;
            ensure!(!text.contains('\0'), "ignore rules contain NUL");
            for line in text.strip_prefix('\u{feff}').unwrap_or(text).lines() {
                if let Some(rule) = parse(line, directory)? {
                    self.count += 1;
                    ensure!(self.count <= MAX_RULES, "ignore rule count bound reached");
                    if plain {
                        self.plain.push(rule);
                    } else {
                        self.git.push(rule);
                    }
                }
            }
        }
        Ok(())
    }
    pub fn ignored(&self, path: &str, directory: bool) -> bool {
        // ripgrep assigns .ignore a higher priority than every .gitignore,
        // including a .gitignore deeper in the tree. Within a type last wins.
        self.plain
            .iter()
            .rev()
            .chain(self.git.iter().rev())
            .find_map(|rule| {
                if rule.directory_only && !directory {
                    return None;
                }
                let relative = if rule.base.is_empty() {
                    path
                } else {
                    path.strip_prefix(&rule.base)?.strip_prefix('/')?
                };
                rule.expression
                    .is_match(relative)
                    .then_some(!rule.whitelist)
            })
            .unwrap_or(false)
    }
}
fn parse(line: &str, base: &str) -> Result<Option<Rule>> {
    // Only unescaped trailing spaces are discarded; '\ ' is a literal space.
    let mut end = line.len();
    while line.as_bytes().get(end.wrapping_sub(1)) == Some(&b' ') {
        let slashes = line.as_bytes()[..end - 1]
            .iter()
            .rev()
            .take_while(|&&b| b == b'\\')
            .count();
        if slashes % 2 == 1 {
            break;
        }
        end -= 1;
    }
    let line = &line[..end];
    if line.is_empty() || line.starts_with('#') {
        return Ok(None);
    }
    let (whitelist, line) = if let Some(rest) = line.strip_prefix('!') {
        (true, rest)
    } else {
        (false, line)
    };
    if line.is_empty() || line == "/" {
        return Ok(None);
    }
    ensure!(line.len() <= 1024, "ignore pattern exceeds byte bound");
    let directory_only = line.ends_with('/') && !line.ends_with("\\/");
    let line = if directory_only {
        &line[..line.len() - 1]
    } else {
        line
    };
    // Gitignore has no brace expansion. Retain its backslash escapes, while
    // quoting braces before reusing the bounded pathname-glob compiler.
    let mut pattern = String::new();
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            let next = chars.next().context("unterminated ignore escape")?;
            ensure!(
                next != '/',
                "escaped ignore path separators are unsupported"
            );
            pattern.push(c);
            pattern.push(next);
        } else {
            if matches!(c, '{' | '}') {
                pattern.push('\\');
            }
            pattern.push(c);
        }
    }
    Ok(Some(Rule {
        base: base.into(),
        expression: super::glob(&pattern).context("unsupported or malformed ignore pattern")?,
        directory_only,
        whitelist,
    }))
}
