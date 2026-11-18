//! Confined byte snapshots become either reversible text views or explicitly
//! derived document views. Derived views never grant overwrite authorization.
use super::*;
use crate::document_extract::extract_office_bytes;

const DOCUMENT_TEXT_BYTES: usize = 256 * 1024;
const PAGE_BYTES: usize = 100_000;

pub(super) async fn read(tools: &LocalTools, args: Value, context: &TurnContext) -> Result<Value> {
    known(&args, &["path", "offset", "limit"])?;
    if string(&args, "path")?.starts_with(python_output::OUTPUT_PREFIX) {
        return tools
            .read_python_output(
                args,
                context,
                Some(tools.execution_scope(context)?.generation),
            )
            .await;
    }
    let path = rel(string(&args, "path")?)?;
    let offset = number(&args, "offset", 1, 1_000_000)?;
    ensure!(offset > 0, "offset is 1-indexed");
    let limit = number(&args, "limit", 2000, 2000)?;
    ensure!(limit > 0, "limit must be positive");
    let owner = tools.read_scope(context)?;
    let inner = tools.inner.clone();
    tokio::task::spawn_blocking(move || {
        let (data, snap) = snapshot(&inner.root, &path, inner.cfg.file_bytes)?;
        let view = view(&data, &path)?;
        let lines = view.text.lines().collect::<Vec<_>>();
        let mut out = String::new();
        let mut count = 0;
        for (i, line) in lines.iter().enumerate().skip(offset - 1).take(limit) {
            let line = format!("{}|{}\n", i + 1, line);
            if out.len() + line.len() > PAGE_BYTES {
                break;
            }
            out.push_str(&line);
            count += 1;
        }
        let next = offset - 1 + count;
        ensure!(
            count > 0 || offset > lines.len() || lines.is_empty(),
            "one line exceeds the bounded text view; cannot mark a complete read"
        );
        let complete = if view.derived || view.encoding.is_some() {
            false
        } else {
            record_read(&inner, owner, &path, &snap, offset, next, lines.len())
        };
        Ok(json!({"path":path,"content":out,"total_lines":lines.len(),
            "next_offset":if next<lines.len(){Some(next+1)}else{None},
            "complete_read":complete,"sha256":snap.hash,
            "extracted_document":view.derived,"document_format":view.format,
            "text_encoding":view.encoding.unwrap_or("utf-8"),"transcoded":view.encoding.is_some(),
            "document_truncated":view.truncated,"warnings":view.warnings,
            "extraction_complete":view.derived && !view.truncated && next>=lines.len()}))
    })
    .await?
}

fn record_read(
    inner: &Inner,
    owner: String,
    path: &str,
    snap: &Snapshot,
    offset: usize,
    next: usize,
    total: usize,
) -> bool {
    let key = (owner, path.to_owned());
    let mut windows = inner.read_windows.lock().unwrap();
    let contiguous = offset == 1
        || windows
            .get(&key)
            .is_some_and(|(old, end)| old == snap && *end == offset);
    let complete = contiguous && next >= total;
    if contiguous {
        if windows.len() >= 4096 {
            windows.clear();
        }
        windows.insert(key.clone(), (snap.clone(), next + 1));
    }
    drop(windows);
    if complete {
        let mut reads = inner.reads.lock().unwrap();
        if reads.len() >= 4096 {
            reads.clear();
        }
        reads.insert(key, snap.clone());
    }
    complete
}

struct View {
    text: String,
    derived: bool,
    format: Option<String>,
    truncated: bool,
    warnings: Vec<String>,
    encoding: Option<&'static str>,
}
fn view(data: &[u8], path: &str) -> Result<View> {
    let ext = Path::new(path)
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if matches!(ext.as_str(), "docx" | "xlsx" | "pptx" | "odt") {
        let doc = extract_office_bytes(data, path)?;
        let mut text = String::new();
        for section in doc.sections {
            text.push_str(&format!("# {}\n{}\n\n", section.source, section.text));
        }
        return Ok(View {
            text,
            derived: true,
            format: Some(doc.format),
            truncated: doc.truncated,
            warnings: doc.warnings,
            encoding: None,
        });
    }
    if matches!(
        ext.as_str(),
        "pdf"
            | "doc"
            | "xls"
            | "ppt"
            | "rtf"
            | "docm"
            | "xlsm"
            | "pptm"
            | "ods"
            | "odp"
            | "epub"
            | "db"
            | "sqlite"
            | "sqlite3"
    ) {
        bail!(
            "this document format has no offline local-file extractor; no external program or network was invoked"
        );
    }
    let (text, encoding) = decode_text(data, path)?;
    // Upstream falls back to the ordinary JSON text view for malformed notebooks.
    if ext == "ipynb"
        && let Ok(mut notebook) = notebook(&text)
    {
        notebook.encoding = encoding;
        return Ok(notebook);
    }
    Ok(View {
        text,
        derived: false,
        format: None,
        truncated: false,
        warnings: if encoding.is_some() {
            vec!["Transcoded UTF-16 to UTF-8 for display. This view does not authorize an overwrite or patch of the original bytes.".into()]
        } else {
            vec![]
        },
        encoding,
    })
}

/// Strict decoding preserves the raw-byte fence. UTF-16 is a display-only rescue,
/// never a raw-read grant. Upstream's replacement decoding is intentionally absent.
pub(super) fn decode_text(data: &[u8], path: &str) -> Result<(String, Option<&'static str>)> {
    let utf8 = std::str::from_utf8(data).ok().filter(|s| !s.contains('\0'));
    if let Some(text) = utf8 {
        return Ok((normalize_text(text), None));
    }
    ensure!(!binary_extension(path), "binary file is not supported");
    ensure!(
        data.len() <= 10 * 1024 * 1024,
        "UTF-16 rescue byte bound exceeded"
    );
    let sample = &data[..data.len().min(512)];
    let little = if sample.starts_with(&[0xff, 0xfe]) {
        true
    } else if sample.starts_with(&[0xfe, 0xff]) {
        false
    } else {
        let even = sample.iter().step_by(2).filter(|&&b| b == 0).count();
        let odd = sample
            .iter()
            .skip(1)
            .step_by(2)
            .filter(|&&b| b == 0)
            .count();
        if even == 0 && odd >= 2 {
            true
        } else if odd == 0 && even >= 2 {
            false
        } else {
            bail!("file is neither supported UTF-8 nor identifiable UTF-16 text");
        }
    };
    ensure!(
        data.len().is_multiple_of(2),
        "invalid UTF-16: odd byte count"
    );
    let units = data.as_chunks::<2>().0.iter().map(|pair| {
        if little {
            u16::from_le_bytes([pair[0], pair[1]])
        } else {
            u16::from_be_bytes([pair[0], pair[1]])
        }
    });
    let text = char::decode_utf16(units)
        .collect::<std::result::Result<String, _>>()
        .context("invalid UTF-16: unpaired surrogate")?;
    ensure!(!text.contains('\0'), "binary file is not supported");
    // A lone BOM was rejected by the previous strict reader; keep that refusal.
    ensure!(
        !text.trim_start_matches('\u{feff}').is_empty(),
        "UTF-16 has no text"
    );
    Ok((
        normalize_text(&text),
        Some(if little { "utf-16-le" } else { "utf-16-be" }),
    ))
}
fn normalize_text(text: &str) -> String {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    if text.contains('\r') {
        text.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        text.to_owned()
    }
}
/// Pinned tools/binary_extensions.py, including SQLite sidecars. This guard only
/// controls UTF-16 rescue; supported Office extraction runs before this decoder.
fn binary_extension(path: &str) -> bool {
    let ext = Path::new(path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if ["db", "sqlite", "sqlite3"].iter().any(|base| {
        ["-wal", "-shm", "-journal"]
            .iter()
            .any(|suffix| ext == format!("{base}{suffix}"))
    }) {
        return true;
    }
    matches!(
        ext.as_str(),
        "png"
            | "jpg"
            | "jpeg"
            | "gif"
            | "bmp"
            | "ico"
            | "webp"
            | "tiff"
            | "tif"
            | "mp4"
            | "mov"
            | "avi"
            | "mkv"
            | "webm"
            | "wmv"
            | "flv"
            | "m4v"
            | "mpeg"
            | "mpg"
            | "mp3"
            | "wav"
            | "ogg"
            | "flac"
            | "aac"
            | "m4a"
            | "wma"
            | "aiff"
            | "opus"
            | "zip"
            | "tar"
            | "gz"
            | "bz2"
            | "7z"
            | "rar"
            | "xz"
            | "z"
            | "tgz"
            | "iso"
            | "exe"
            | "dll"
            | "so"
            | "dylib"
            | "bin"
            | "o"
            | "a"
            | "obj"
            | "lib"
            | "app"
            | "msi"
            | "deb"
            | "rpm"
            | "doc"
            | "docx"
            | "xls"
            | "xlsx"
            | "ppt"
            | "pptx"
            | "odt"
            | "ods"
            | "odp"
            | "ttf"
            | "otf"
            | "woff"
            | "woff2"
            | "eot"
            | "pyc"
            | "pyo"
            | "class"
            | "jar"
            | "war"
            | "ear"
            | "node"
            | "wasm"
            | "rlib"
            | "sqlite"
            | "sqlite3"
            | "db"
            | "mdb"
            | "idx"
            | "psd"
            | "ai"
            | "eps"
            | "sketch"
            | "fig"
            | "xd"
            | "blend"
            | "3ds"
            | "max"
            | "swf"
            | "fla"
            | "lockb"
            | "dat"
            | "data"
    )
}

fn source(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Array(items) => items.iter().filter_map(Value::as_str).collect(),
        _ => String::new(),
    }
}
fn cleaned_output(text: &str) -> String {
    // ANSI CSI / OSC escapes are display controls, not notebook output text.
    static ESCAPE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let escape = ESCAPE.get_or_init(|| regex::Regex::new(
        r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[PX^_][\s\S]*?\x1b\\|[ -/]+[0-~]|[0-~])|\x{009b}[0-?]*[ -/]*[@-~]|\x{009d}[\s\S]*?(?:\x07|\x{009c})|[\x{0080}-\x{009f}]"
    ).expect("static ANSI regex"));
    let text = escape.replace_all(text, "").replace("\r\n", "\n");
    text.split('\n')
        .map(|line| line.split('\r').rfind(|s| !s.is_empty()).unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n")
}
fn notebook_output(output: &Value) -> String {
    match output["output_type"].as_str().unwrap_or("") {
        "stream" => cleaned_output(&source(&output["text"])),
        "error" | "pyerr" => {
            let trace = output["traceback"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default();
            format!(
                "Error: {}: {}\n{}",
                output["ename"].as_str().unwrap_or(""),
                output["evalue"].as_str().unwrap_or(""),
                cleaned_output(&trace)
            )
            .trim_end()
            .into()
        }
        "execute_result" | "display_data" | "pyout" => {
            let data = &output["data"];
            if data
                .get("application/vnd.jupyter.widget-view+json")
                .is_some()
            {
                return "[interactive widget — omitted]".into();
            }
            for key in ["text/plain", "text/markdown"] {
                let text = cleaned_output(&source(&data[key]));
                if !text.trim().is_empty() {
                    return text;
                }
            }
            // v3 stores plain text beside output_type, rather than in data.
            if !data.is_object() {
                let text = cleaned_output(&source(&output["text"]));
                if !text.trim().is_empty() {
                    return text;
                }
            }
            "[non-text notebook output omitted]".into()
        }
        _ => String::new(),
    }
}
fn bounded_push(text: &mut String, part: &str, limit: usize) -> bool {
    let mut end = part.len().min(limit.saturating_sub(text.len()));
    while !part.is_char_boundary(end) {
        end -= 1;
    }
    text.push_str(&part[..end]);
    end < part.len()
}
fn notebook(text: &str) -> Result<View> {
    let value: Value = serde_json::from_str(text).context("not a valid notebook")?;
    ensure!(value.is_object(), "notebook root is not an object");
    let cells: Box<dyn Iterator<Item = &Value>> = if let Some(cells) = value["cells"].as_array() {
        Box::new(cells.iter())
    } else {
        Box::new(
            value["worksheets"]
                .as_array()
                .into_iter()
                .flatten()
                .flat_map(|s| s["cells"].as_array().into_iter().flatten()),
        )
    };
    let mut text = String::new();
    let mut counts = [0; 3];
    let mut truncated = false;
    let mut output_count = 0;
    for (cell_index, cell) in cells.enumerate() {
        if cell_index >= 10_000 {
            truncated = true;
            break;
        }
        let (label, i) = match cell["cell_type"].as_str().unwrap_or("") {
            "markdown" => ("Markdown", 0),
            "code" => ("Code", 1),
            "raw" => ("Raw", 2),
            _ => continue,
        };
        counts[i] += 1;
        let suffix = if i == 2 {
            String::new()
        } else {
            format!(" {}", counts[i])
        };
        let part = format!(
            "# ── {label} cell{suffix} ──\n{}\n\n",
            source(&cell["source"]).trim_end_matches('\n')
        );
        truncated |= bounded_push(&mut text, &part, DOCUMENT_TEXT_BYTES);
        if i == 1 {
            let mut outputs = String::new();
            let mut omitted = false;
            for output in cell["outputs"].as_array().into_iter().flatten() {
                output_count += 1;
                if output_count > 10_000 || outputs.len() >= 20_000 {
                    omitted = true;
                    break;
                }
                let rendered = notebook_output(output);
                if !rendered.trim().is_empty() {
                    if !outputs.is_empty() {
                        omitted |= bounded_push(&mut outputs, "\n", 20_000);
                    }
                    omitted |= bounded_push(&mut outputs, &rendered, 20_000);
                }
            }
            if omitted {
                outputs.push_str("\n[notebook cell output truncated]");
                truncated = true;
            }
            if !outputs.is_empty() {
                let part = format!(
                    "# ── Output (cell {}) ──\n{}\n\n",
                    counts[i],
                    outputs.trim_end_matches('\n')
                );
                truncated |= bounded_push(&mut text, &part, DOCUMENT_TEXT_BYTES);
            }
        }
        if text.len() >= DOCUMENT_TEXT_BYTES {
            truncated = true;
            break;
        }
    }
    ensure!(!text.is_empty(), "notebook contains no readable cells");
    text = text.trim_end().to_owned();
    text.push('\n');
    Ok(View { text, encoding: None, derived: true, format: Some("ipynb".into()), truncated,
        warnings: vec!["Notebook source and textual outputs only; code is never executed and rich outputs are omitted. Derived text does not authorize a raw file overwrite.".into()] })
}
