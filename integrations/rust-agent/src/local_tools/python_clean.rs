//! Output-only redaction subset, not upstream's dynamic vault/plugin redactor.
//! Prefix inventory and ANSI grammar adapted from Hermes commit
//! 36b98bcced7f3c22d08dd1119240e726b3928e3d (Nous Research, MIT; see LICENSE.hermes).
use regex::{Captures, Regex};
use serde_json::Value;
use std::sync::OnceLock;
fn regex(slot: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    slot.get_or_init(|| Regex::new(pattern).expect("static Python output regex"))
}
fn prefix_regex() -> &'static Regex {
    static PREFIX: OnceLock<Regex> = OnceLock::new();
    PREFIX.get_or_init(|| {
        let patterns: Vec<String> = serde_json::from_str(include_str!("redaction_prefixes.json"))
            .expect("pinned prefix inventory");
        Regex::new(&format!(r"(^|[^A-Za-z0-9_])({})", patterns.join("|")))
            .expect("pinned linear prefix regex")
    })
}
fn mask(token: &str) -> String {
    if token.chars().count() < 18 {
        "***".into()
    } else {
        format!(
            "{}...{}",
            token.chars().take(6).collect::<String>(),
            token
                .chars()
                .rev()
                .take(4)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<String>()
        )
    }
}
fn placeholder(value: &str) -> bool {
    (value.starts_with('{') && value.ends_with('}'))
        || (value.starts_with("${") && value.ends_with('}'))
        || (value.starts_with('<') && value.ends_with('>'))
        || (value.starts_with('$')
            && value[1..]
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b == b'_'))
}
fn hidden(c: char) -> bool {
    matches!(
        c,
        '\u{200b}'
            | '\u{200c}'
            | '\u{200d}'
            | '\u{2060}'
            | '\u{feff}'
            | '\0'
            | '\u{0008}'
            | '\u{000b}'
            | '\u{000c}'
    )
}
fn mask_split_prefixes(text: &str) -> String {
    if !text.chars().any(hidden) {
        return text.to_owned();
    }
    let mut compact = String::with_capacity(text.len());
    let mut original = Vec::<u32>::new();
    for (at, c) in text.char_indices() {
        if !hidden(c) {
            compact.push(c);
            for n in 0..c.len_utf8() {
                original.push((at + n) as u32);
            }
        }
    }
    original.push(text.len() as u32);
    let mut result = String::new();
    let mut end = 0;
    for captures in prefix_regex().captures_iter(&compact) {
        let token = captures.get(2).unwrap();
        let start = original[token.start()] as usize;
        let stop = original[token.end() - 1] as usize + 1;
        result.push_str(&text[end..start]);
        result.push_str(&mask(token.as_str()));
        end = stop;
    }
    result.push_str(&text[end..]);
    result
}
pub(super) fn clean(text: &str) -> String {
    static ANSI: OnceLock<Regex> = OnceLock::new();
    let ansi = regex(
        &ANSI,
        r"\x1b(?:\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]|\][\s\S]*?(?:\x07|\x1b\\)|[PX^_][\s\S]*?\x1b\\|[\x20-\x2f]+[\x30-\x7e]|[\x30-\x7e])|\u{009b}[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]|\u{009d}[\s\S]*?(?:\x07|\u{009c})|[\u{0080}-\u{009f}]",
    );
    let mut text = if text
        .chars()
        .any(|c| c == '\x1b' || ('\u{0080}'..='\u{009f}').contains(&c))
    {
        ansi.replace_all(text, "").into_owned()
    } else {
        text.to_owned()
    };
    text = mask_split_prefixes(&text);
    text = prefix_regex()
        .replace_all(&text, |c: &Captures<'_>| {
            format!("{}{}", &c[1], mask(&c[2]))
        })
        .into_owned();
    static PEM: OnceLock<Regex> = OnceLock::new();
    if text.contains("PRIVATE KEY-----") {
        text=regex(&PEM,r"(?s)-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----").replace_all(&text,"[REDACTED PRIVATE KEY]").into_owned();
    }
    static JWT: OnceLock<Regex> = OnceLock::new();
    if text.contains("eyJ") {
        text = regex(&JWT, r"eyJ[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_=-]{4,}){0,2}")
            .replace_all(&text, |c: &Captures<'_>| mask(&c[0]))
            .into_owned();
    }
    static AUTH: OnceLock<Regex> = OnceLock::new();
    text = regex(
        &AUTH,
        r#"(?i)(authorization["']?\s*[:=]\s*["']?(?:bearer|basic)\s+)([^\s"',}]+)"#,
    )
    .replace_all(&text, |c: &Captures<'_>| {
        format!("{}{}", &c[1], mask(&c[2]))
    })
    .into_owned();
    static HEADER: OnceLock<Regex> = OnceLock::new();
    text = regex(
        &HEADER,
        r#"(?im)((?:x-api-key|api-key|x-auth-token)["']?\s*:\s*["']?)([^\s"',}]+)"#,
    )
    .replace_all(&text, |c: &Captures<'_>| {
        format!("{}{}", &c[1], mask(&c[2]))
    })
    .into_owned();
    static DB: OnceLock<Regex> = OnceLock::new();
    text=regex(&DB,r"(?i)((?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqp|amqps)://[^\s/@:]*:)([^\s/@]+)(@)").replace_all(&text,|c:&Captures<'_>|if placeholder(&c[2]){c[0].to_owned()}else{format!("{}***{}",&c[1],&c[3])}).into_owned();
    static FLAG: OnceLock<Regex> = OnceLock::new();
    text=regex(&FLAG,r#"(?i)(--(?:api[-_]?key|access[-_]?token|auth[-_]?token|client[-_]?secret|password|passwd)(?:=|\s+)["']?)([^\s"']+)"#).replace_all(&text,|c:&Captures<'_>|if placeholder(&c[2]){c[0].to_owned()}else{format!("{}{}",&c[1],mask(&c[2]))}).into_owned();
    text
}
pub(super) fn failure_hint(trace: &str, enabled: &[String]) -> Option<String> {
    let window = trace.chars().take(4000).collect::<String>();
    static IMPORT: OnceLock<Regex> = OnceLock::new();
    if let Some(c) = regex(
        &IMPORT,
        r"cannot import name '([A-Za-z_][A-Za-z0-9_]*)' from 'hermes_tools'",
    )
    .captures(&window)
    {
        let name = &c[1];
        return Some(if ["json_parse", "shell_quote", "retry"].contains(&name) {
            format!(
                "Import with from hermes_tools import {name}. If this import failed, the session module may have been modified; reset=true starts a fresh authorized bridge."
            )
        } else {
            format!(
                "'{name}' is unavailable inside execute_code. Importable host-authorized tools: {}. Use an enabled normal tool call for other operations.",
                enabled
                    .iter()
                    .take(128)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        });
    }
    static HELPER: OnceLock<Regex> = OnceLock::new();
    if let Some(c) = regex(
        &HELPER,
        r"NameError: name '(json_parse|shell_quote|retry)' is not defined",
    )
    .captures(&window)
    {
        return Some(format!(
            "Import {} before calling it: from hermes_tools import {}",
            &c[1], &c[1]
        ));
    }
    static MODULE: OnceLock<Regex> = OnceLock::new();
    if let Some(c) = regex(
        &MODULE,
        r"ModuleNotFoundError: No module named '([A-Za-z0-9_.]+)'",
    )
    .captures(&window)
    {
        return Some(format!(
            "'{}' is not installed in the configured sandbox interpreter. Use the Python standard library or ask the host to configure an approved runtime; reset after runtime changes. This tool cannot install packages or launch subprocesses.",
            &c[1]
        ));
    }
    if window.contains("TypeError: string indices must be integers")
        || window.contains("AttributeError: 'str' object has no attribute 'get'")
    {
        return Some("Bridge helpers return already-parsed dictionaries. Check the failing value's type; use read_file(path)['content'] rather than parsing the whole tool result as a string.".into());
    }
    None
}
pub(super) fn stale_warning(names: &Value) -> Option<String> {
    let names = names
        .as_array()?
        .iter()
        .take(32)
        .filter_map(Value::as_str)
        .filter(|name| {
            !name.is_empty()
                && name.len() <= 200
                && name.split('.').all(|part| {
                    !part.is_empty()
                        && (part.as_bytes()[0].is_ascii_alphabetic() || part.starts_with('_'))
                        && part.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                })
        })
        .collect::<Vec<_>>();
    if names.is_empty() {
        return None;
    }
    Some(format!(
        "Edited on disk after this kernel imported it: {}{}. If used without reloading, this cell ran OLD code. Use importlib.reload(module) and re-import names taken from it, or reset=true for fresh imports.",
        clean(&names.iter().take(8).copied().collect::<Vec<_>>().join(", ")),
        if names.len() > 8 {
            format!(" and {} more", names.len() - 8)
        } else {
            String::new()
        }
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_errors_and_source_while_cleaning_credentials() {
        let input = "\x1b[31mTraceback\x1b[0m: fail\nMAX_TOKENS=100\n{'apiKey':'test'}\npostgresql://{user}:{password}@{host}\nsk-synthetic01234567890123456789\nAuthorization: Bearer synthetic-secret-token-123456\n";
        let output = clean(input);
        assert!(output.contains("Traceback: fail\nMAX_TOKENS=100"));
        assert!(output.contains("{'apiKey':'test'}"));
        assert!(output.contains("{password}"));
        assert!(!output.contains("\x1b"));
        assert!(!output.contains("sk-synthetic01234567890123456789"));
        assert!(!output.contains("synthetic-secret-token-123456"));
    }
    #[test]
    fn strips_osc_c1_and_masks_zero_width_splits() {
        let text = "a\x1b]0;secret-title\x07b\u{009b}31mc\u{009b}0m ghp_abcdefghij\u{200b}klmnopqrstuv\nreal error";
        let out = clean(text);
        assert!(out.starts_with("abc "));
        assert!(!out.contains("abcdefghij"));
        assert!(out.ends_with("\nreal error"));
    }
    #[test]
    fn hints_and_stale_names_are_bounded() {
        assert!(
            failure_hint("ModuleNotFoundError: No module named 'absent'", &[])
                .unwrap()
                .contains("standard library")
        );
        assert!(
            stale_warning(&serde_json::json!([
                "pkg.module",
                "bad\nname",
                "../outside"
            ]))
            .unwrap()
            .contains("pkg.module")
        );
        assert!(stale_warning(&serde_json::json!(["../outside"])).is_none());
    }
}
