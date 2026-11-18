//! Bounded data-only YAML subset. No tags, aliases, merge keys or evaluation.
//! Full YAML is intentionally not claimed: unsupported syntax stays raw text on
//! reads and is rejected on new writes. Parsing never supplies host authority.
use super::*;
use serde_json::Map;

pub(super) struct Frontmatter<'a> {
    pub fields: Map<String, Value>,
    pub body: &'a str,
    pub warning: Option<String>,
}

pub(super) fn split(content: &str) -> Option<(&str, &str)> {
    let content = content.strip_prefix('\u{feff}').unwrap_or(content);
    let (first, rest) = content.split_once('\n')?;
    if first.trim_end() != "---" {
        return None;
    }
    let mut offset = 0;
    for line in rest.split_inclusive('\n') {
        if line.ends_with('\n') && line.trim() == "---" {
            return Some((&rest[..offset], &rest[offset + line.len()..]));
        }
        offset += line.len();
    }
    None
}

pub(super) fn read(content: &str) -> Frontmatter<'_> {
    let Some((header, body)) = split(content) else {
        return Frontmatter {
            fields: Map::new(),
            body: content,
            warning: Some(
                "Missing or unclosed YAML frontmatter; metadata was not interpreted".into(),
            ),
        };
    };
    match parse(header) {
        Ok(fields) => Frontmatter {
            fields,
            body,
            warning: None,
        },
        Err(error) => Frontmatter {
            fields: Map::new(),
            body,
            warning: Some(format!(
                "Unsupported or invalid frontmatter: {error}; metadata was not interpreted"
            )),
        },
    }
}

pub(super) fn parse(header: &str) -> Result<Map<String, Value>> {
    ensure!(header.len() <= 32 * 1024, "frontmatter exceeds 32 KiB");
    let lines = header.lines().collect::<Vec<_>>();
    ensure!(lines.len() <= 512, "frontmatter exceeds 512 lines");
    for line in &lines {
        ensure!(
            line.len() <= 4096 && !line.contains('\0'),
            "invalid frontmatter line"
        );
        ensure!(
            !line
                .chars()
                .take_while(|c| c.is_whitespace())
                .any(|c| c == '\t'),
            "tab indentation is unsupported"
        );
    }
    let mut parser = Parser {
        lines,
        pos: 0,
        nodes: 0,
    };
    parser.skip();
    ensure!(
        parser.pos < parser.lines.len(),
        "frontmatter must be a mapping"
    );
    ensure!(
        indent(parser.lines[parser.pos]) == 0,
        "frontmatter starts indented"
    );
    let value = parser.block(0, 0)?;
    parser.skip();
    ensure!(parser.pos == parser.lines.len(), "inconsistent indentation");
    value
        .as_object()
        .cloned()
        .context("frontmatter must be a mapping")
}

fn indent(line: &str) -> usize {
    line.bytes().take_while(|c| *c == b' ').count()
}
fn is_item(text: &str) -> bool {
    text == "-" || text.starts_with("- ")
}
struct Parser<'a> {
    lines: Vec<&'a str>,
    pos: usize,
    nodes: usize,
}
impl Parser<'_> {
    fn skip(&mut self) {
        while self.pos < self.lines.len()
            && (self.lines[self.pos].trim().is_empty()
                || self.lines[self.pos].trim_start().starts_with('#'))
        {
            self.pos += 1;
        }
    }
    fn block(&mut self, level: usize, depth: usize) -> Result<Value> {
        ensure!(depth <= 12, "frontmatter nesting exceeds 12");
        self.skip();
        ensure!(self.pos < self.lines.len(), "missing nested value");
        let sequence = is_item(self.lines[self.pos].trim());
        let mut array = vec![];
        let mut map = Map::new();
        loop {
            self.skip();
            if self.pos == self.lines.len() || indent(self.lines[self.pos]) < level {
                break;
            }
            let line = self.lines[self.pos];
            ensure!(indent(line) == level, "inconsistent indentation");
            self.pos += 1;
            let text = line.trim();
            if sequence {
                ensure!(is_item(text), "mixed sequence and mapping");
                array.push(self.value(text[1..].trim(), level, depth + 1)?);
            } else {
                ensure!(!is_item(text), "mixed mapping and sequence");
                let (key, raw) = text.split_once(':').context("mapping entry needs ':'")?;
                let key = parse_key(key)?;
                ensure!(!map.contains_key(&key), "duplicate metadata key");
                map.insert(key, self.value(raw.trim(), level, depth + 1)?);
            }
        }
        Ok(if sequence {
            Value::Array(array)
        } else {
            Value::Object(map)
        })
    }
    fn value(&mut self, raw: &str, level: usize, depth: usize) -> Result<Value> {
        let raw = strip_comment(raw).trim();
        if raw.is_empty() {
            self.skip();
            return if self.pos < self.lines.len() && indent(self.lines[self.pos]) > level {
                self.block(indent(self.lines[self.pos]), depth)
            } else {
                Ok(Value::Null)
            };
        }
        if matches!(raw, "|" | "|-" | "|+" | ">" | ">-" | ">+") {
            let start = self.pos;
            while self.pos < self.lines.len()
                && (self.lines[self.pos].trim().is_empty() || indent(self.lines[self.pos]) > level)
            {
                self.pos += 1;
            }
            let block = &self.lines[start..self.pos];
            let base = block
                .iter()
                .find(|l| !l.trim().is_empty())
                .map(|l| indent(l))
                .unwrap_or(level + 1);
            ensure!(
                block
                    .iter()
                    .all(|l| l.trim().is_empty() || indent(l) >= base),
                "inconsistent block-string indentation"
            );
            let lines = block
                .iter()
                .map(|line| line.get(base..).unwrap_or(""))
                .collect::<Vec<_>>();
            let ordinary = |line: &str| !line.is_empty() && !line.starts_with(' ');
            let mut out = String::new();
            for (i, text) in lines.iter().enumerate() {
                out.push_str(text);
                let next = lines.get(i + 1).copied();
                if raw.starts_with('>') && ordinary(text) && next.is_some_and(ordinary) {
                    out.push(' ');
                } else if raw.starts_with('>')
                    && text.is_empty()
                    && next.is_some_and(ordinary)
                    && lines[..i]
                        .iter()
                        .rev()
                        .find(|s| !s.is_empty())
                        .is_some_and(|s| ordinary(s))
                {
                    // One empty line separates folded paragraphs with one LF;
                    // extra empties and more-indented blocks retain their LFs.
                } else {
                    out.push('\n');
                }
            }
            if raw.ends_with('-') {
                out.truncate(out.trim_end_matches('\n').len());
            } else if !raw.ends_with('+') && !out.is_empty() {
                out.truncate(out.trim_end_matches('\n').len());
                out.push('\n');
            }
            self.nodes += 1;
            ensure!(self.nodes <= 512, "frontmatter exceeds 512 values");
            return Ok(Value::String(out));
        }
        scalar(raw, depth, &mut self.nodes)
    }
}
fn parse_key(raw: &str) -> Result<String> {
    let raw = raw.trim();
    ensure!(
        !raw.is_empty()
            && raw.len() <= 128
            && raw
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b)),
        "unsupported metadata key"
    );
    Ok(raw.into())
}
fn strip_comment(raw: &str) -> &str {
    // Quoted/flow values own their internal '#' characters.
    if raw.starts_with(['\'', '"', '[', '{']) {
        return raw;
    }
    for (index, _) in raw.match_indices('#') {
        if index == 0 || raw[..index].ends_with(char::is_whitespace) {
            return raw[..index].trim_end();
        }
    }
    raw
}
fn scalar(raw: &str, depth: usize, nodes: &mut usize) -> Result<Value> {
    *nodes += 1;
    ensure!(
        depth <= 12 && *nodes <= 512,
        "frontmatter nesting/value bound reached"
    );
    let raw = strip_comment(raw).trim();
    if raw.starts_with('[') || raw.starts_with('{') {
        let closing = if raw.starts_with('[') { ']' } else { '}' };
        ensure!(raw.ends_with(closing), "unclosed flow collection");
        let parts = flow_parts(&raw[1..raw.len() - 1])?;
        if closing == ']' {
            return Ok(Value::Array(
                parts
                    .into_iter()
                    .map(|p| scalar(p, depth + 1, nodes))
                    .collect::<Result<_>>()?,
            ));
        }
        let mut map = Map::new();
        for part in parts {
            let (key, value) = part
                .split_once(':')
                .context("flow mapping entry needs ':'")?;
            let key = parse_key(key)?;
            ensure!(!map.contains_key(&key), "duplicate metadata key");
            map.insert(key, scalar(value.trim(), depth + 1, nodes)?);
        }
        return Ok(Value::Object(map));
    }
    if raw.starts_with('"') {
        let mut stream = serde_json::Deserializer::from_str(raw).into_iter::<String>();
        let value = stream.next().context("missing quoted string")??;
        let tail = raw[stream.byte_offset()..].trim();
        ensure!(
            tail.is_empty() || tail.starts_with('#'),
            "characters after quoted string"
        );
        return Ok(Value::String(value));
    }
    if let Some(rest) = raw.strip_prefix('\'') {
        let mut value = String::new();
        let mut chars = rest.char_indices().peekable();
        while let Some((i, c)) = chars.next() {
            if c == '\'' {
                if chars.peek().is_some_and(|(_, c)| *c == '\'') {
                    chars.next();
                    value.push('\'');
                } else {
                    let tail = rest[i + 1..].trim();
                    ensure!(
                        tail.is_empty() || tail.starts_with('#'),
                        "characters after quoted string"
                    );
                    return Ok(Value::String(value));
                }
            } else {
                value.push(c);
            }
        }
        bail!("unclosed single-quoted string");
    }
    ensure!(
        !raw.starts_with(['&', '*', '!', '|', '>', '@', '`']) && !raw.contains(": "),
        "unsupported YAML scalar, tag or alias"
    );
    if raw.is_empty() || matches!(raw, "null" | "Null" | "NULL" | "~") {
        return Ok(Value::Null);
    }
    if matches!(raw, "true" | "True" | "TRUE") {
        return Ok(Value::Bool(true));
    }
    if matches!(raw, "false" | "False" | "FALSE") {
        return Ok(Value::Bool(false));
    }
    if let Ok(value) = serde_json::from_str::<Value>(raw)
        && value.is_number()
    {
        return Ok(value);
    }
    Ok(Value::String(raw.into()))
}
fn flow_parts(raw: &str) -> Result<Vec<&str>> {
    if raw.trim().is_empty() {
        return Ok(vec![]);
    }
    let mut parts = vec![];
    let mut start = 0;
    let mut depth = 0i32;
    let mut quote = None;
    let mut escaped = false;
    for (i, c) in raw.char_indices() {
        if let Some(q) = quote {
            if escaped {
                escaped = false;
            } else if q == '"' && c == '\\' {
                escaped = true;
            } else if c == q {
                quote = None;
            }
        } else if c == '\'' || c == '"' {
            quote = Some(c);
        } else if c == '[' || c == '{' {
            depth += 1;
        } else if c == ']' || c == '}' {
            depth -= 1;
            ensure!(depth >= 0, "unbalanced flow collection");
        } else if c == ',' && depth == 0 {
            ensure!(!raw[start..i].trim().is_empty(), "empty flow item");
            parts.push(raw[start..i].trim());
            start = i + 1;
        }
    }
    ensure!(quote.is_none() && depth == 0, "unbalanced flow collection");
    if !raw[start..].trim().is_empty() {
        parts.push(raw[start..].trim());
    }
    Ok(parts)
}

pub(super) fn tags(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|v| match v {
                Value::String(s) if !s.trim().is_empty() => Some(s.trim().into()),
                _ => None,
            })
            .collect(),
        Some(Value::String(text)) => text
            .trim()
            .trim_start_matches('[')
            .trim_end_matches(']')
            .split(',')
            .map(|s| s.trim().trim_matches(['\'', '"']).to_owned())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn folded_paragraphs_literal_strings_and_quotes() -> Result<()> {
        // Expected strings also checked against the upstream safe YAML loader.
        for (raw, expected) in [
            ("description: >\n  foo\n  \n  bar\n", "foo\nbar\n"),
            ("description: >-\n  foo\n  \n  \n  bar\n", "foo\n\nbar"),
            (
                "description: >\n  foo\n  \n    code\n  \n  bar\n",
                "foo\n\n  code\n\nbar\n",
            ),
            ("description: |+\n  foo\n  bar\n\n", "foo\nbar\n\n"),
            ("description: 'can''t # split' # outside\n", "can't # split"),
            (
                "description: \"quote: # text\" # outside\n",
                "quote: # text",
            ),
        ] {
            assert_eq!(parse(raw)?["description"], expected, "{raw}");
        }
        assert_eq!(
            parse("metadata: {hermes: {tags: [a, b]}}\n")?["metadata"]["hermes"]["tags"],
            json!(["a", "b"])
        );
        Ok(())
    }
    #[test]
    fn parser_bounds_and_malformed_collections_are_explicit() {
        for header in [
            "x: [a,,b]".into(),
            "x: [a, {b: c]".into(),
            "x: >\n    first\n  broken".into(),
            "x: &a value\ny: *a".into(),
            format!("x: {}", "[".repeat(14) + "a" + &"]".repeat(14)),
            format!("x: [{}]", "a,".repeat(513)),
            format!("x: {}", "a".repeat(4096)),
            "x: value\n".repeat(513),
            "x: value\nx: other".into(),
        ] {
            assert!(parse(&header).is_err(), "{header}");
        }
    }
}
