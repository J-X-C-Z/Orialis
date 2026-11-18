use super::*;
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
};
const COOKIE_KEYS: &[&str] = &["SESSDATA", "bili_jct", "buvid3", "buvid4", "DedeUserID"];
#[derive(Clone)]
pub struct Credentials(BTreeMap<String, String>);
impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Credentials([redacted])")
    }
}
impl Credentials {
    pub fn from_value(value: &Value) -> Result<Self> {
        let object = value.as_object().context("B站专用凭据格式无效")?;
        let mut out = BTreeMap::new();
        for (k, v) in object {
            ensure!(COOKIE_KEYS.contains(&k.as_str()), "B站专用凭据包含未知字段");
            let v = v.as_str().context("B站专用凭据格式无效")?;
            ensure!(
                v.len() <= 8192
                    && v.is_ascii()
                    && !v
                        .bytes()
                        .any(|b| b <= 32 || b == 127 || b";,\"\\".contains(&b)),
                "B站专用凭据格式无效"
            );
            if !v.is_empty() {
                out.insert(k.clone(), v.into());
            }
        }
        ensure!(
            out.contains_key("SESSDATA"),
            "B站专用凭据缺少登录状态，请重新通过专用二维码授权"
        );
        Ok(Self(out))
    }
    pub(super) fn header(&self) -> String {
        self.0
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    }
    pub fn fields(&self) -> Vec<String> {
        self.0.keys().cloned().collect()
    }
}
#[derive(Clone)]
pub struct CredentialStore {
    path: PathBuf,
    optional: bool,
}
impl std::fmt::Debug for CredentialStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CredentialStore([private path])")
    }
}
impl CredentialStore {
    pub fn new(path: &Path) -> Result<Self> {
        Self::path(path, false)
    }
    /// Use only for the host's documented default path, where missing means anonymous.
    pub fn optional(path: &Path) -> Result<Self> {
        Self::path(path, true)
    }
    fn path(path: &Path, optional: bool) -> Result<Self> {
        ensure!(
            path.is_absolute() && !path.components().any(|c| matches!(c, Component::ParentDir)),
            "B站专用凭据路径必须是绝对路径且不可穿越父目录"
        );
        Ok(Self {
            path: path.to_owned(),
            optional,
        })
    }
    /// Preflight an explicitly authorized login destination without reading cookies.
    /// Creates missing owner-private directories; never creates/replaces credentials.
    pub async fn prepare_for_login(&self) -> Result<()> {
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            check_parent(&path, true)?;
            match fs::symlink_metadata(&path) {
                #[cfg(unix)]
                Ok(meta) => check_file(&meta),
                #[cfg(not(unix))]
                Ok(_) => bail!("private Bilibili credentials require Unix permissions"),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(_) => bail!("授权文件无法安全写入"),
            }
        })
        .await
        .context("credential preflight stopped")?
    }
    pub async fn load(&self) -> Result<Option<Credentials>> {
        let this = self.clone();
        tokio::task::spawn_blocking(move || this.read())
            .await
            .context("credential reader stopped")?
    }
    fn read(&self) -> Result<Option<Credentials>> {
        match fs::symlink_metadata(&self.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && self.optional => return Ok(None),
            Err(_) => bail!("指定的B站专用凭据文件不存在或无法读取，请通过专用二维码授权"),
            Ok(_) => {}
        }
        check_parent(&self.path, false)?;
        #[cfg(unix)]
        let mut file = {
            use std::os::unix::fs::OpenOptionsExt;
            OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
                .open(&self.path)
                .map_err(|_| anyhow::anyhow!("B站专用凭据文件无法安全读取"))?
        };
        #[cfg(not(unix))]
        {
            bail!("private Bilibili credentials require Unix permissions");
        }
        #[cfg(unix)]
        {
            check_file(&file.metadata()?)?;
            let mut bytes = Vec::new();
            std::io::Read::by_ref(&mut file)
                .take(65537)
                .read_to_end(&mut bytes)
                .map_err(|_| anyhow::anyhow!("B站专用凭据无法读取"))?;
            ensure!(bytes.len() <= 65536, "B站专用凭据过大");
            let value = serde_json::from_slice(&bytes)
                .map_err(|_| anyhow::anyhow!("B站专用凭据格式无效"))?;
            Ok(Some(Credentials::from_value(&value)?))
        }
    }
    async fn save(
        &self,
        credentials: Credentials,
        cancelled: Arc<AtomicBool>,
    ) -> Result<Vec<String>> {
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            let fields = credentials.fields();
            let bytes = serde_json::to_vec(&credentials.0)?;
            write_private(&path, &bytes, Some(&cancelled))?;
            Ok(fields)
        })
        .await
        .context("credential writer stopped")?
    }
}
#[cfg(unix)]
fn check_file(meta: &fs::Metadata) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    ensure!(
        meta.is_file()
            && meta.uid() == unsafe { libc::geteuid() }
            && meta.nlink() == 1
            && meta.mode() & 0o777 == 0o600,
        "专用授权文件必须是当前用户拥有的600权限普通文件"
    );
    Ok(())
}
fn check_parent(path: &Path, create: bool) -> Result<()> {
    ensure!(
        path.is_absolute() && !path.components().any(|c| matches!(c, Component::ParentDir)),
        "授权文件路径必须是绝对路径"
    );
    let parent = path.parent().context("missing credential directory")?;
    let mut ancestors = parent.ancestors().collect::<Vec<_>>();
    ancestors.reverse();
    for ancestor in ancestors {
        if !ancestor.exists() && create {
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(ancestor)
                    .map_err(|_| anyhow::anyhow!("无法创建专用授权目录"))?;
            }
        }
        let meta =
            fs::symlink_metadata(ancestor).map_err(|_| anyhow::anyhow!("专用授权目录不可用"))?;
        ensure!(
            meta.is_dir() && !meta.file_type().is_symlink(),
            "授权目录不可为符号链接"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let uid = unsafe { libc::geteuid() };
            ensure!(meta.uid() == uid || meta.uid() == 0, "授权目录所有者无效");
            ensure!(
                meta.mode() & 0o022 == 0
                    || (ancestor != parent && meta.uid() == 0 && meta.mode() & 0o1000 != 0),
                "授权目录不能由其他用户写入"
            );
        }
    }
    Ok(())
}
fn write_private(path: &Path, bytes: &[u8], cancelled: Option<&AtomicBool>) -> Result<()> {
    check_parent(path, true)?;
    match fs::symlink_metadata(path) {
        Ok(meta) => {
            ensure!(!meta.file_type().is_symlink(), "授权文件不能是符号链接");
            #[cfg(unix)]
            check_file(&meta)?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => bail!("授权文件无法安全写入"),
    }
    let parent = path.parent().unwrap();
    let temporary = parent.join(format!(".bili-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        #[cfg(unix)]
        let mut file = {
            use std::os::unix::fs::OpenOptionsExt;
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&temporary)?
        };
        #[cfg(not(unix))]
        {
            bail!("private Bilibili credentials require Unix permissions");
        }
        #[cfg(unix)]
        {
            file.write_all(bytes)?;
            file.sync_all()?;
            ensure!(
                !cancelled.is_some_and(|c| c.load(Ordering::SeqCst)),
                "B站授权已取消，未保存新凭据"
            );
            fs::rename(&temporary, path)?;
            fs::File::open(parent)?.sync_all()?;
            Ok(())
        }
    })();
    let _ = fs::remove_file(&temporary);
    result.map_err(|_| anyhow::anyhow!("授权文件未能安全保存，旧凭据保持不变或结果需要检查"))
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LoginState {
    AwaitingScan,
    AwaitingConfirmation,
    Authorized { fields: Vec<String> },
    Expired,
    Cancelled,
    Failed,
}
#[derive(Clone)]
pub struct LoginCancellation(Arc<AtomicBool>);
impl LoginCancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
}
pub struct BiliLogin {
    http: http::BiliHttp,
    store: CredentialStore,
}
impl BiliLogin {
    #[cfg(test)]
    pub(super) fn with_http(store: CredentialStore, http: http::BiliHttp) -> Self {
        Self { store, http }
    }
    pub fn new(store: CredentialStore) -> Result<Self> {
        Ok(Self {
            http: http::BiliHttp::new()?,
            store,
        })
    }
    /// Explicit opt-in only. The host must obtain authorization for this login and
    /// storing an ongoing account session before invoking it. No automatic login.
    pub async fn begin(&self, timeout: Duration) -> Result<LoginSession> {
        ensure!(
            (Duration::from_secs(15)..=Duration::from_secs(300)).contains(&timeout),
            "二维码有效期必须为15–300秒"
        );
        self.store.prepare_for_login().await?;
        let expires = Instant::now() + timeout;
        let (data, _) = self
            .http
            .login(
                "/x/passport-login/web/qrcode/generate",
                &params(&[("source", "main-fe-header")]),
                expires,
            )
            .await?;
        let key = data["qrcode_key"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control))
            .context("平台未返回有效二维码")?
            .to_owned();
        let link = data["url"].as_str().context("平台未返回有效二维码")?;
        let u = http::allowed_url(link, false, true)?;
        ensure!(
            link.starts_with("https://") && u.host_str() == Some("passport.bilibili.com"),
            "二维码目标不是B站登录服务"
        );
        let code =
            qrcode::QrCode::new(link.as_bytes()).map_err(|_| anyhow::anyhow!("无法生成二维码"))?;
        let width = code.width();
        let scale = 6u32;
        let side = (width as u32 + 8) * scale;
        let picture = image::GrayImage::from_fn(side, side, |x, y| {
            let x = (x / scale) as isize - 4;
            let y = (y / scale) as isize - 4;
            image::Luma([
                if x >= 0
                    && y >= 0
                    && (x as usize) < width
                    && (y as usize) < width
                    && code[(x as usize, y as usize)] == qrcode::Color::Dark
                {
                    0
                } else {
                    255
                },
            ])
        });
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageLuma8(picture).write_to(&mut png, image::ImageFormat::Png)?;
        Ok(LoginSession {
            http: self.http.clone(),
            store: self.store.clone(),
            key,
            png: png.into_inner(),
            expires,
            last_poll: None,
            state: LoginState::AwaitingScan,
            cancelled: Arc::new(AtomicBool::new(false)),
        })
    }
}
/// Contains transient login material; intentionally neither Debug nor Serialize.
pub struct LoginSession {
    http: http::BiliHttp,
    store: CredentialStore,
    key: String,
    png: Vec<u8>,
    expires: Instant,
    last_poll: Option<Instant>,
    state: LoginState,
    cancelled: Arc<AtomicBool>,
}
impl LoginSession {
    pub fn state(&self) -> LoginState {
        if matches!(
            self.state,
            LoginState::Authorized { .. }
                | LoginState::Failed
                | LoginState::Expired
                | LoginState::Cancelled
        ) {
            self.state.clone()
        } else if self.cancelled.load(Ordering::SeqCst) {
            LoginState::Cancelled
        } else if Instant::now() >= self.expires
            && !matches!(self.state, LoginState::Authorized { .. })
        {
            LoginState::Expired
        } else {
            self.state.clone()
        }
    }
    pub fn expires_in(&self) -> Duration {
        self.expires.saturating_duration_since(Instant::now())
    }
    pub fn qr_png(&self) -> &[u8] {
        if matches!(
            self.state(),
            LoginState::AwaitingScan | LoginState::AwaitingConfirmation
        ) {
            &self.png
        } else {
            &[]
        }
    }
    pub fn cancellation(&self) -> LoginCancellation {
        LoginCancellation(self.cancelled.clone())
    }
    pub fn cancel(&mut self) {
        if matches!(
            self.state,
            LoginState::Authorized { .. }
                | LoginState::Failed
                | LoginState::Expired
                | LoginState::Cancelled
        ) {
            return;
        }
        self.cancelled.store(true, Ordering::SeqCst);
        self.key.clear();
        self.png.clear();
        self.state = LoginState::Cancelled;
    }
    pub async fn write_qr(&self, path: &Path) -> Result<()> {
        ensure!(
            matches!(
                self.state(),
                LoginState::AwaitingScan | LoginState::AwaitingConfirmation
            ),
            "二维码已失效或授权已结束"
        );
        ensure!(path != self.store.path, "二维码文件与凭据文件必须不同");
        let path = path.to_owned();
        let png = self.png.clone();
        let cancel = self.cancelled.clone();
        tokio::task::spawn_blocking(move || write_private(&path, &png, Some(&cancel))).await?
    }
    pub async fn poll(&mut self) -> Result<LoginState> {
        let state = self.state();
        if !matches!(
            state,
            LoginState::AwaitingScan | LoginState::AwaitingConfirmation
        ) {
            self.state = state.clone();
            return Ok(state);
        }
        if let Some(last) = self.last_poll {
            tokio::time::sleep_until((last + Duration::from_secs(3)).min(self.expires)).await;
        }
        if self.cancelled.load(Ordering::SeqCst) {
            self.cancel();
            return Ok(LoginState::Cancelled);
        }
        if Instant::now() >= self.expires {
            self.state = LoginState::Expired;
            self.key.clear();
            return Ok(self.state.clone());
        }
        self.last_poll = Some(Instant::now());
        let response = self
            .http
            .login(
                "/x/passport-login/web/qrcode/poll",
                &params(&[("source", "main-fe-header"), ("qrcode_key", &self.key)]),
                self.expires,
            )
            .await;
        if self.cancelled.load(Ordering::SeqCst) {
            self.cancel();
            return Ok(LoginState::Cancelled);
        }
        let (data, cookies) = match response {
            Ok(v) => v,
            Err(_) => {
                self.state = LoginState::Failed;
                self.key.clear();
                bail!("B站授权检查失败，未保存新的凭据")
            }
        };
        self.state = match data["code"].as_i64() {
            Some(86101) => LoginState::AwaitingScan,
            Some(86090) => LoginState::AwaitingConfirmation,
            Some(86038) => LoginState::Expired,
            Some(0) => {
                ensure!(
                    Instant::now() < self.expires,
                    "二维码授权已超时，未保存新凭据"
                );
                let saved = async {
                    let credentials = cookies_from_headers(&cookies)?;
                    self.store.save(credentials, self.cancelled.clone()).await
                }
                .await;
                match saved {
                    Ok(fields) => LoginState::Authorized { fields },
                    Err(_) => {
                        self.state = LoginState::Failed;
                        self.key.clear();
                        self.png.clear();
                        bail!("B站授权未能安全完成，未确认保存新凭据");
                    }
                }
            }
            _ => {
                self.key.clear();
                self.state = LoginState::Failed;
                bail!("B站扫码返回未支持的状态，未保存新的凭据")
            }
        };
        if !matches!(
            self.state,
            LoginState::AwaitingScan | LoginState::AwaitingConfirmation
        ) {
            self.key.clear();
            self.png.clear();
        }
        Ok(self.state.clone())
    }
}
impl Drop for LoginSession {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }
}
fn cookies_from_headers(headers: &[String]) -> Result<Credentials> {
    let mut values = BTreeMap::new();
    for header in headers {
        ensure!(
            header.len() <= 16384 && !header.contains(['\r', '\n']),
            "B站授权Cookie格式无效"
        );
        let mut parts = header.split(';');
        let Some((name, value)) = parts.next().and_then(|v| v.split_once('=')) else {
            continue;
        };
        let name = name.trim();
        if !COOKIE_KEYS.contains(&name) {
            continue;
        }
        for attribute in parts {
            if let Some((k, v)) = attribute.trim().split_once('=') {
                if k.eq_ignore_ascii_case("domain") {
                    ensure!(
                        matches!(
                            v.trim_start_matches('.').to_ascii_lowercase().as_str(),
                            "bilibili.com" | "passport.bilibili.com"
                        ),
                        "登录Cookie域名无效"
                    );
                }
                if k.eq_ignore_ascii_case("max-age") {
                    ensure!(v.parse::<i64>().is_ok_and(|n| n > 0), "登录Cookie已过期");
                }
            }
        }
        ensure!(!values.contains_key(name), "B站授权Cookie重复");
        let raw = value.trim();
        let raw = if raw.starts_with('"') || raw.ends_with('"') {
            ensure!(
                raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"'),
                "B站授权Cookie格式无效"
            );
            &raw[1..raw.len() - 1]
        } else {
            raw
        };
        ensure!(
            !raw.contains(['"', '\\'])
                && raw.is_ascii()
                && !raw.bytes().any(|b| b <= 32 || b == 127),
            "B站授权Cookie格式无效"
        );
        let mut value = raw.to_owned();
        if name == "SESSDATA" && !value.contains('%') {
            const SAFE: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
                .remove(b'-')
                .remove(b'_')
                .remove(b'.')
                .remove(b'~')
                .remove(b'/');
            value = percent_encoding::utf8_percent_encode(&value, SAFE).to_string();
        }
        values.insert(name.to_owned(), value);
    }
    Credentials::from_value(&serde_json::to_value(values)?)
}
