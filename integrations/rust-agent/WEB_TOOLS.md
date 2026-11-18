# Explicit web search and public static extraction

`src/web_tools.rs` implements the fixed Hermes `web_search` and `web_extract`
contracts without importing a browser session, managed account, model API key,
proxy, or remote scraping service. The host must opt in. Nothing is fetched when
constructing `WebTools` or listing schemas.

## Host API and configuration

- `WebTools::new(WebConfig) -> Result<WebTools>`; clones share concurrency limits.
- `WebTools::schemas()` and its `ToolExecutor` implementation advertise
  `web_extract`. They advertise `web_search` **only** when `config.search` is set.
  The free `schemas()` function describes both contracts for inspection; it is
  not the host capability registry.
- `WebTools::execute(name, arguments).await -> Value` returns the actual tool JSON;
  `ToolExecutor` adapts it to the trusted host tool router.
- `SearchConfig { provider: SearchProvider::{Brave, Firecrawl}, endpoint, api_key }`
  requires an explicit HTTPS endpoint and separate nonempty credential. No
  credential is discovered from environment variables by this module. Host CLI
  configuration is separate. Endpoint userinfo, query and fragment are refused.
  Credential headers are marked sensitive, and debug output redacts the key.
- Official endpoint shapes implemented: Brave
  `https://api.search.brave.com/res/v1/web/search` and Firecrawl
  `https://api.firecrawl.dev/v2/search`. A deliberately configured compatible
  HTTPS endpoint is allowed, subject to the same public-network restrictions.

Defaults: 30-second **total** call deadline (including queued work), 4 MiB maximum
wire body and decompressed body/text, 5 redirects, 4 simultaneous tool calls,
3 concurrent pages per batch, 2 parser workers, 200,000 DOM nodes and depth 256.
Validated configuration maxima are 120 seconds, 20 MiB, 10 redirects, 16 calls
and 300,000 DOM nodes. An oversized response is an error, not partial success.
All HTTP bodies are streamed with actual-byte checks even without Content-Length.
HTML-generated text is separately bounded, including repeated expanded links.

## Exact contracts and supported behavior

References are the pinned original files at upstream Hermes commit
`36b98bcced7f3c22d08dd1119240e726b3928e3d`:
`tools/web_tools.py`, `tools/web_tools_extract.py`,
`plugins/web/brave_free/provider.py`, and `plugins/web/firecrawl/provider.py`.

`web_search` accepts required `query` and optional integer `limit` (default 5,
clamped 1–100). Brave uses GET `q` and `count` (maximum 20, matching the provider)
with `X-Subscription-Token`. Firecrawl uses POST `{query, limit}` with Bearer
credentials. Success is `{success:true,data:{web:[{title,url,description,position}]}}`;
positions are one-based. Failures are `{success:false,error}`. Malformed, private
literal or credential-bearing result URLs are omitted, not fetched. Result
snippet text is bounded and an exact echoed configured credential is redacted.
The configured endpoint is contacted once: redirects, automatic HTTP retries
and provider fallback are disabled. HTTP/provider failure does not imply search
success; raw provider error bodies and credentials are not returned.

`web_extract` accepts 1–5 `urls`, optional integer `char_limit` (default 15,000,
clamped 2,000–500,000), and the upstream compatibility `format` argument
(`markdown` or `text`). URL strings and objects with string `url`/`href` are
accepted. Results preserve input order and use
`{results:[{url,title,content,error}]}` with `error:null` only after actual fetch,
decode and extraction succeeded. A bad URL produces an individual error;
credential-bearing URLs reject the entire batch before any request.
Unrecognized fields (including headers, cookies, auth and browser actions)
return `not_supported`, rather than silently accepting them.

Direct extraction supports static HTML/XHTML, plain text and text JSON/XML.
HTML is parsed, not executed: main/article/body content, title, headings,
paragraphs, lists, table text, safe absolute links, image placeholders and pre
text are preserved. Scripts, style/template/iframe/object/form content and
obvious hidden/navigation/footer content are excluded. No script, stylesheet,
image or link is automatically fetched. HTTP charset, BOM and HTML meta charset
are decoded with `encoding_rs`; invalid bytes or unknown encodings fail clearly.
Gzip and zlib-wrapped deflate are decoded with separate decompressed-byte limits.
An empty/JavaScript-only page is an error, not fabricated extracted content.

Long output uses the original head/tail approach (75%/25%, Unicode characters).
The truncation footer honestly states **full text was not stored**. No invented
local path is returned. Like upstream, the footer is additional to the requested
content-character budget.

## Network and trust boundary

Only credential-free HTTP(S) public destinations are supported. File/FTP and
other schemes, local hostnames, loopback/private/link-local/reserved/multicast,
CGNAT, metadata/control addresses, IPv4-mapped private IPv6, non-global IPv6,
6to4/Teredo/documentation ranges are refused. All DNS answers must be public;
one private answer rejects the destination. Each connection uses a new client
with the validated address set pinned to the exact hostname, proxies disabled,
redirects disabled and normal TLS verification intact. This removes the second
DNS-resolution/rebinding window. Every redirect repeats URL and DNS validation,
with loop/hop checks and no HTTPS downgrade. Redirects never carry a provider
credential; provider endpoints do not follow redirects at all.

Common token query keys, URL userinfo, recognized vendor-token patterns and
encoded controls are refused, including repeated percent decoding. This is a
conservative guard, not a claim to recognize every possible secret embedded in
arbitrary page text or URLs. Page content and search snippets remain **untrusted
data**, not instructions or authorization. The host retains tool authorization.
There is no internal-network override in production. Exact localhost fixture
mapping and injected DNS answers exist only behind `cfg(test)` and are not
exposed by configuration, CLI or production constructors.

## Explicit limits and differences

- This is not browser automation. JavaScript rendering, clicking, logging in,
  cookies, user credentials, screenshots, CAPTCHA and remote Firecrawl scrape
  are not implemented. Firecrawl **search** is distinct from remote scrape;
  opaque scraper DNS/redirect behavior is not assumed safe.
- Direct web PDF/Office/media extraction is `not_supported`. The separate
  attachment `DocumentExtractor` handles explicitly configured PDF/Office input.
- Unsupported content encodings such as Brotli are rejected; the client requests
  only gzip/deflate. HTML-to-Markdown is bounded static extraction, not full CSS
  layout, JavaScript DOM or full-fidelity table conversion.
- No paid-search result cache, upstream managed/keyless rescue, full-text spool,
  browser account, or undocumented provider is claimed.
- Literal secret detection is best effort. Results do not authorize follow-up
  actions, and extraction never passes page instructions to a shell or browser.

## Reproducible evidence

```
CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test web_tools -- --nocapture
```

`tests/web_tools.rs` runs a real local HTTP server in the same test-process tree,
using a non-resolving fixture hostname and an exact test-only pinned address.
It checks real HTML content, no script/subresource requests, headers, redirects,
body streaming, gzip, charsets/BOM, Unicode truncation, unsupported content,
Brave GET/Firecrawl POST payloads and authentication, real provider response
normalization, secret redaction, no retry and no credential-bearing redirect.
Additional cases cover private/mixed/empty DNS answers, redirect DNS checks,
DOM depth/node/output expansion budgets and encoded secret batch preflight.

**No real Brave or Firecrawl account, credential, paid request or live official
search service was used.** Fixture contract tests are not represented as live
provider acceptance. Live authenticated provider validation remains an operator
acceptance step when an explicitly authorized endpoint and independent key are
available.
