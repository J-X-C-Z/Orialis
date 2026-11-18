//! Durable attachment references and on-demand provider hydration. Inline image
//! bytes are never written into chat history. Source metadata remains bound to
//! its original conversation/input and is revalidated by AttachmentTransport.
use crate::{
    attachments::{self, AttachmentMetadata, AttachmentTransport, ModelInputLimits},
    tool_runtime::TurnContext,
};
use anyhow::{Context, Result, ensure};
use futures_util::future::BoxFuture;
use serde_json::{Value, json};

pub const MEDIA_FIELD: &str = "_orialis_attachments";
pub struct ResolvedMedia {
    pub message: Value,
    pub lease: Box<dyn Send + Sync>,
}
pub trait MediaResolver: Send + Sync {
    fn hydrate<'a>(&'a self, message: &'a Value) -> BoxFuture<'a, Result<ResolvedMedia>>;
}
pub struct OrialisMediaResolver {
    pub transport: AttachmentTransport,
    pub limits: ModelInputLimits,
}
pub fn user_reference(
    text: &str,
    items: &[AttachmentMetadata],
    context: &TurnContext,
) -> Result<Value> {
    ensure!(
        text.len() <= 256 * 1024 && items.len() <= attachments::MAX_ATTACHMENTS,
        "message too large"
    );
    ensure!(
        !text.trim().is_empty() || !items.is_empty(),
        "empty message"
    );
    for item in items {
        item.validate()?;
    }
    let mut message = json!({"role":"user","content":text});
    if !items.is_empty() {
        ensure!(
            !context.conversation_id.is_empty() && !context.input_id.is_empty(),
            "attachment source context missing"
        );
        message[MEDIA_FIELD] = json!({"conversation_id":context.conversation_id,"input_id":context.input_id,"items":items});
    }
    Ok(message)
}
impl MediaResolver for OrialisMediaResolver {
    fn hydrate<'a>(&'a self, message: &'a Value) -> BoxFuture<'a, Result<ResolvedMedia>> {
        Box::pin(async move {
            let Some(source) = message.get(MEDIA_FIELD) else {
                return Ok(ResolvedMedia {
                    message: message.clone(),
                    lease: Box::new(()),
                });
            };
            ensure!(
                message["role"] == "user",
                "media only belongs to user input"
            );
            let items: Vec<AttachmentMetadata> = serde_json::from_value(source["items"].clone())
                .context("invalid stored attachment references")?;
            let conversation = source["conversation_id"]
                .as_str()
                .context("missing stored conversation")?;
            let input = source["input_id"]
                .as_str()
                .context("missing stored input")?;
            let files = self
                .transport
                .fetch_message(conversation, input, &items)
                .await?;
            let prepared = attachments::prepare_model_input(
                message["content"].as_str().unwrap_or(""),
                &files,
                &self.limits,
            )
            .await?;
            Ok(ResolvedMedia {
                message: prepared.message,
                lease: Box::new(files),
            })
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn durable_reference_is_not_inline_file_data() {
        let ctx = TurnContext {
            conversation_id: "conv".into(),
            input_id: "input".into(),
            session_id: "session".into(),
        };
        let a = AttachmentMetadata {
            id: "file1".into(),
            name: "a.txt".into(),
            mime_type: "text/plain".into(),
            size: Some(2),
            download_url: "http://127.0.0.1/api/v1/attachments/file1/download".into(),
        };
        let v = user_reference("", &[a], &ctx).unwrap();
        assert_eq!(v[MEDIA_FIELD]["conversation_id"], "conv");
        assert!(v.to_string().contains("file1"));
        assert!(!v.to_string().contains("data:"));
    }
    #[test]
    fn source_context_required_for_media() {
        let a = AttachmentMetadata {
            id: "file1".into(),
            name: "a.txt".into(),
            mime_type: "text/plain".into(),
            size: Some(2),
            download_url: "http://127.0.0.1/api/v1/attachments/file1/download".into(),
        };
        assert!(user_reference("", &[a], &TurnContext::default()).is_err());
    }
}
