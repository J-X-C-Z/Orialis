use super::*;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use std::net::{IpAddr, Ipv4Addr};
const SOURCE_HOSTS: &[&str] = &[
    "bilibili.com",
    "www.bilibili.com",
    "m.bilibili.com",
    "b23.tv",
];
pub(super) fn source_url(value: &str) -> bool {
    url::parse(value).is_ok_and(|u| SOURCE_HOSTS.contains(&u.host_str().unwrap_or("")))
}
// Deliberately stricter than arbitrary web URLs: normalized HTTPS, fixed origins,
// no literal IPs/custom ports, credentials/control characters or backslash tricks.
pub(super) fn allowed_url(value: &str, media: bool, login: bool) -> Result<reqwest::Url> {
    let value = if value.starts_with("//") {
        format!("https:{value}")
    } else {
        value.to_owned()
    };
    let mut u = url::parse(&value)?;
    let host = u.host_str().context("missing video host")?;
    let allowed = if login {
        host == "passport.bilibili.com"
    } else {
        SOURCE_HOSTS.contains(&host)
            || host == "api.bilibili.com"
            || (media && (host.ends_with(".hdslb.com") || host.ends_with(".bilivideo.com")))
    };
    ensure!(
        allowed && u.port().is_none_or(|p| p == 443),
        "视频地址不属于受支持的平台"
    );
    u.set_scheme("https")
        .map_err(|_| anyhow::anyhow!("invalid video scheme"))?;
    u.set_fragment(None);
    Ok(u)
}
pub(super) mod url {
    use super::*;
    pub fn parse(value: &str) -> Result<reqwest::Url> {
        ensure!(
            value.len() <= 8192
                && (value.starts_with("http://") || value.starts_with("https://"))
                && !value
                    .chars()
                    .any(|c| c.is_control() || c.is_whitespace() || c == '\\'),
            "视频地址不可用"
        );
        let u = reqwest::Url::parse(value).map_err(|_| anyhow::anyhow!("视频地址不可用"))?;
        ensure!(
            u.host_str().is_some()
                && u.username().is_empty()
                && u.password().is_none()
                && u.port().is_none_or(|p| p == 80 || p == 443),
            "视频地址不可用"
        );
        Ok(u)
    }
}
fn public_v4(v: Ipv4Addr) -> bool {
    let n = u32::from(v);
    let in_net = |base: u32, bits: u32| n >> (32 - bits) == base >> (32 - bits);
    ![
        (0x00000000, 8),
        (0x0a000000, 8),
        (0x64400000, 10),
        (0x7f000000, 8),
        (0xa9fe0000, 16),
        (0xac100000, 12),
        (0xc0000000, 24),
        (0xc0000200, 24),
        (0xc0586300, 24),
        (0xc0a80000, 16),
        (0xc6120000, 15),
        (0xc6336400, 24),
        (0xcb007100, 24),
        (0xe0000000, 4),
        (0xf0000000, 4),
    ]
    .iter()
    .any(|(base, bits)| in_net(*base, *bits))
}
pub(super) fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => public_v4(v),
        IpAddr::V6(v) => {
            let s = v.segments();
            s[0] & 0xe000 == 0x2000
                && !(s[0] == 0x2001 && (s[1] < 0x200 || s[1] == 0xdb8))
                && s[0] != 0x2002
                && !(s[0] == 0x3fff && s[1] < 0x1000)
        }
    }
}
struct PublicDns;
impl Resolve for PublicDns {
    fn resolve(&self, name: Name) -> Resolving {
        Box::pin(async move {
            let addrs: Vec<_> = tokio::net::lookup_host((name.as_str(), 443))
                .await?
                .collect();
            if addrs.is_empty() || addrs.iter().any(|a| !public_ip(a.ip())) {
                return Err(std::io::Error::other(
                    "video DNS did not resolve exclusively to public addresses",
                )
                .into());
            }
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}
#[derive(Default)]
pub(super) struct Reply {
    pub status: u16,
    pub body: Vec<u8>,
    pub location: Option<String>,
    pub set_cookies: Vec<String>,
}
pub(super) trait Transport: Send + Sync {
    fn get<'a>(
        &'a self,
        url: &'a reqwest::Url,
        cookies: Option<&'a str>,
        limit: usize,
        deadline: Instant,
    ) -> BoxFuture<'a, Result<Reply>>;
}
struct PublicHttp {
    client: reqwest::Client,
}
impl Transport for PublicHttp {
    fn get<'a>(
        &'a self,
        url: &'a reqwest::Url,
        cookies: Option<&'a str>,
        limit: usize,
        deadline: Instant,
    ) -> BoxFuture<'a, Result<Reply>> {
        Box::pin(async move {
            let mut call = self.client.get(url.clone()).timeout(
                deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_secs(
                        if url.host_str() == Some("passport.bilibili.com") {
                            10
                        } else {
                            8
                        },
                    )),
            );
            if let Some(c) = cookies {
                call = call.header(reqwest::header::COOKIE, c);
            }
            let mut response = call
                .send()
                .await
                .map_err(|_| anyhow::anyhow!("平台视频请求失败"))?;
            let status = response.status().as_u16();
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .map(|h| h.to_str().map(str::to_owned))
                .transpose()
                .map_err(|_| anyhow::anyhow!("invalid video redirect"))?;
            let set_cookies = response
                .headers()
                .get_all(reqwest::header::SET_COOKIE)
                .iter()
                .map(|h| h.to_str().map(str::to_owned))
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| anyhow::anyhow!("invalid login response cookies"))?;
            // Redirect/error bodies are never needed; do not retain diagnostic secrets.
            let mut body = Vec::new();
            if status == 200 {
                ensure!(
                    response.content_length().unwrap_or(0) <= limit as u64,
                    "视频证据超过读取大小限制"
                );
                while let Some(chunk) = response
                    .chunk()
                    .await
                    .map_err(|_| anyhow::anyhow!("视频内容读取失败"))?
                {
                    ensure!(
                        body.len() + chunk.len() <= limit,
                        "视频证据超过读取大小限制"
                    );
                    body.extend_from_slice(&chunk);
                }
            }
            Ok(Reply {
                status,
                body,
                location,
                set_cookies,
            })
        })
    }
}
#[derive(Clone)]
pub(super) struct BiliHttp {
    transport: Arc<dyn Transport>,
    cookies: Option<Credentials>,
}
impl BiliHttp {
    pub fn new() -> Result<Self> {
        let client = reqwest::Client::builder()
            .dns_resolver(Arc::new(PublicDns))
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(8))
            .pool_max_idle_per_host(2)
            .user_agent("Mozilla/5.0 Orialis/1.0")
            .default_headers({
                let mut h = reqwest::header::HeaderMap::new();
                h.insert(
                    reqwest::header::REFERER,
                    "https://www.bilibili.com/".parse()?,
                );
                h.insert(reqwest::header::ACCEPT_ENCODING, "identity".parse()?);
                h
            })
            .build()?;
        Ok(Self {
            transport: Arc::new(PublicHttp { client }),
            cookies: None,
        })
    }
    pub fn with_credentials(&self, cookies: Option<Credentials>) -> Self {
        Self {
            transport: self.transport.clone(),
            cookies,
        }
    }
    #[cfg(test)]
    pub fn loopback_reader() -> Arc<dyn Transport> {
        Arc::new(PublicHttp {
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .retry(reqwest::retry::never())
                .build()
                .unwrap(),
        })
    }
    #[cfg(test)]
    pub fn mock(transport: Arc<dyn Transport>) -> Self {
        Self {
            transport,
            cookies: None,
        }
    }
    pub async fn fetch(
        &self,
        input: &str,
        media: bool,
        limit: usize,
        resolve_only: bool,
        deadline: Instant,
    ) -> Result<(Vec<u8>, String)> {
        let mut next = input.to_owned();
        for _ in 0..4 {
            let u = allowed_url(&next, media, false)?;
            let host = u.host_str().unwrap();
            if resolve_only
                && SOURCE_HOSTS.contains(&host)
                && host != "b23.tv"
                && u.path().starts_with("/video/")
            {
                return Ok((Vec::new(), u.to_string()));
            }
            let cookie = if host == "bilibili.com" || host.ends_with(".bilibili.com") {
                self.cookies.as_ref().map(Credentials::header)
            } else {
                None
            };
            let response = tokio::time::timeout_at(
                deadline,
                self.transport.get(&u, cookie.as_deref(), limit, deadline),
            )
            .await
            .context("视频内容读取超时")??;
            if matches!(response.status, 301 | 302 | 303 | 307 | 308) {
                let location = response.location.context("视频短链接未返回有效目标")?;
                next = u
                    .join(&location)
                    .map_err(|_| anyhow::anyhow!("视频重定向无效"))?
                    .to_string();
                continue;
            }
            match response.status {
                200 => {}
                401 => bail!("B站登录状态未被接受，请重新通过专用二维码授权"),
                403 | 412 => {
                    bail!("B站仍限制当前服务器访问；专用登录授权不保证解除限制，请稍后重试")
                }
                _ => bail!("平台暂时无法提供视频内容"),
            }
            ensure!(response.body.len() <= limit, "视频证据超过读取大小限制");
            return Ok((response.body, u.to_string()));
        }
        bail!("视频链接重定向次数过多")
    }
    pub async fn data(
        &self,
        path: &str,
        params: &BTreeMap<String, String>,
        deadline: Instant,
    ) -> Result<Value> {
        ensure!(
            matches!(
                path,
                "/x/web-interface/view"
                    | "/x/web-interface/nav"
                    | "/x/web-interface/wbi/search/type"
                    | "/x/player/v2"
                    | "/x/player/videoshot"
            ),
            "unsupported Bilibili API"
        );
        let url = format!("https://api.bilibili.com{path}?{}", query(params));
        let (raw, _) = self
            .fetch(&url, false, 1024 * 1024, false, deadline)
            .await?;
        let payload: Value =
            serde_json::from_slice(&raw).map_err(|_| anyhow::anyhow!("平台返回无效视频信息"))?;
        ensure!(
            payload["code"].as_i64() == Some(0) && payload["data"].is_object(),
            "视频信息暂不可用，可能需要平台登录或受访问限制"
        );
        Ok(payload["data"].clone())
    }
    pub async fn login(
        &self,
        path: &str,
        params: &BTreeMap<String, String>,
        deadline: Instant,
    ) -> Result<(Value, Vec<String>)> {
        ensure!(
            matches!(
                path,
                "/x/passport-login/web/qrcode/generate" | "/x/passport-login/web/qrcode/poll"
            ),
            "invalid Bilibili login operation"
        );
        let u = allowed_url(
            &format!("https://passport.bilibili.com{path}?{}", query(params)),
            false,
            true,
        )?;
        // Login does not send preexisting account cookies and never follows redirects.
        let reply =
            tokio::time::timeout_at(deadline, self.transport.get(&u, None, 256 * 1024, deadline))
                .await
                .context("二维码授权超时")??;
        ensure!(
            reply.status == 200 && reply.body.len() <= 256 * 1024,
            "B站登录接口暂不可用，请稍后重试"
        );
        let body: Value = serde_json::from_slice(&reply.body)
            .map_err(|_| anyhow::anyhow!("B站登录接口返回无效数据"))?;
        ensure!(
            body["code"].as_i64() == Some(0) && body["data"].is_object(),
            "B站登录接口未接受请求，请稍后重试"
        );
        Ok((body["data"].clone(), reply.set_cookies))
    }
}
pub(super) fn query(params: &BTreeMap<String, String>) -> String {
    reqwest::Url::parse_with_params("https://example.invalid/", params)
        .expect("static URL")
        .query()
        .unwrap_or("")
        .to_owned()
}
