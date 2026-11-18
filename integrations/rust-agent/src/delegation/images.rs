use super::*;
use crate::workspace::ProtectedRoot;
use base64::{Engine, engine::general_purpose::STANDARD};
use std::{
    io::{Cursor, Read},
    sync::OnceLock,
};

pub trait DelegationImages: Send + Sync {
    /// Stable trusted scope identifier used to prevent widened continuation access.
    fn scope_identity(&self) -> String;
    fn resolve<'a>(&'a self, reference: &'a str) -> BoxFuture<'a, Result<Value>>;
}
/// Reads only relative paths under an explicitly authorized root. Symlinks,
/// absolute paths, URLs and traversal are rejected by ProtectedRoot. HTTP image
/// fetching and parent attachments need a separately configured resolver.
#[derive(Clone)]
pub struct WorkspaceImages {
    root: ProtectedRoot,
    scope: String,
}
impl WorkspaceImages {
    pub fn new(root: ProtectedRoot, trusted_scope: &str) -> Result<Self> {
        ensure!(
            !trusted_scope.is_empty() && trusted_scope.len() <= 4096,
            "image scope identity required"
        );
        Ok(Self {
            root,
            scope: digest(trusted_scope),
        })
    }
}
impl DelegationImages for WorkspaceImages {
    fn scope_identity(&self) -> String {
        format!("workspace-images-v1:{}", self.scope)
    }
    fn resolve<'a>(&'a self, reference: &'a str) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            static CPU: OnceLock<Arc<Semaphore>> = OnceLock::new();
            let permit = CPU
                .get_or_init(|| Arc::new(Semaphore::new(2)))
                .clone()
                .acquire_owned()
                .await?;
            let root = self.root.clone();
            let reference = reference.to_owned();
            tokio::task::spawn_blocking(move||{
                let _permit=permit;
                let file=root.open_file(&reference)?;let mut bytes=Vec::new();file.take(8*1024*1024+1).read_to_end(&mut bytes)?;
                ensure!(bytes.len()<=8*1024*1024,"child image source byte limit exceeded");
                let reader=image::ImageReader::new(Cursor::new(&bytes)).with_guessed_format()?;
                let (width,height)=reader.into_dimensions()?;
                ensure!(width>0&&height>0&&(width as u64)*(height as u64)<=4_000_000,"child image pixel budget exceeded");
                let mut reader=image::ImageReader::new(Cursor::new(&bytes)).with_guessed_format()?;
                let mut limits=image::Limits::default();limits.max_image_width=Some(4096);limits.max_image_height=Some(4096);limits.max_alloc=Some(32*1024*1024);reader.limits(limits);
                let decoded=reader.decode()?;
                let mut image=decoded.thumbnail(1024,1024);
                for _ in 0..5 {
                    let rgb=image.to_rgb8();let mut jpeg=Vec::new();image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg,75).encode_image(&rgb)?;
                    if jpeg.len()<=256*1024{return Ok(json!({"type":"image_url","image_url":{"url":format!("data:image/jpeg;base64,{}",STANDARD.encode(jpeg))}}))}
                    image=image.thumbnail((image.width()/2).max(1),(image.height()/2).max(1));
                }bail!("child image encode budget exceeded")
            }).await?
        })
    }
}
