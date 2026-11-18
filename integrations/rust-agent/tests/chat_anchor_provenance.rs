use anyhow::Result;
use hermes_rust_core::journal::Journal;
use serde_json::json;
fn frame(id: &str, conv: &str) -> serde_json::Value {
    json!({"version":1,"type":"message.send","message_id":id,"conversation_id":conv,"content":"synthetic authorized input"})
}
const IDENTITY: &str = "ws://127.0.0.1:1234/api/v1/agent/ws|AA_Test_Rust|fixture-owner-scope";
#[tokio::test]
async fn real_inbound_is_bound_immutable_and_survives_reopen() -> Result<()> {
    let tmp = tempfile::tempdir()?;
    let p = tmp.path().join("journal.db");
    let j = Journal::open(&p, IDENTITY).await?;
    j.claim("chat:root", &frame("root", "conv")).await?;
    let a = j.proven_chat_anchor("root", "conv").await?.unwrap();
    assert_eq!(a.input_id(), "root");
    assert_eq!(a.message_id(), "root");
    assert_eq!(a.conversation_id(), "conv");
    assert!(a.is_bound_to(
        "ws://127.0.0.1:1234/api/v1/agent/ws",
        "AA_Test_Rust",
        "fixture-owner-scope"
    ));
    assert!(!a.is_bound_to(
        "ws://127.0.0.1:1235/api/v1/agent/ws",
        "AA_Test_Rust",
        "fixture-owner-scope"
    ));
    assert!(!a.is_bound_to(
        "ws://127.0.0.1:1234/api/v1/agent/ws",
        "AA_Other_Rust",
        "fixture-owner-scope"
    ));
    assert!(!a.is_bound_to(
        "ws://127.0.0.1:1234/api/v1/agent/ws",
        "AA_Test_Rust",
        "other-owner"
    ));
    assert!(j.proven_chat_anchor("root", "other").await?.is_none());
    let mut changed = frame("root", "conv");
    changed["content"] = json!("changed");
    assert!(j.claim("chat:root", &changed).await.is_err());
    assert_eq!(
        j.proven_chat_anchor("root", "conv")
            .await?
            .unwrap()
            .payload_fingerprint(),
        a.payload_fingerprint()
    );
    j.shutdown().await?;
    drop(j);
    let j = Journal::open(&p, IDENTITY).await?;
    assert_eq!(
        j.proven_chat_anchor("root", "conv")
            .await?
            .unwrap()
            .payload_fingerprint(),
        a.payload_fingerprint()
    );
    j.shutdown().await?;
    Ok(())
}
#[tokio::test]
async fn synthetic_namespaces_and_invalid_frames_are_not_human_provenance() -> Result<()> {
    let tmp = tempfile::tempdir()?;
    let j = Journal::open(&tmp.path().join("db"), IDENTITY).await?;
    j.claim("delivery:notice", &frame("notice", "conv")).await?;
    j.claim("chat:outgoing",&json!({"version":1,"type":"message.reply","message_id":"outgoing","reply_to":"root","conversation_id":"conv","content":"answer"})).await?;
    j.claim("chat:invalid",&json!({"version":1,"type":"message.send","message_id":"invalid","conversation_id":"conv","content":""})).await?;
    j.claim("chat:other-name", &frame("mismatch", "conv"))
        .await?;
    for id in ["notice", "outgoing", "invalid", "mismatch", "other-name"] {
        assert!(j.proven_chat_anchor(id, "conv").await?.is_none());
    }
    j.shutdown().await?;
    Ok(())
}
#[tokio::test]
async fn legacy_final_does_not_invent_anchor_but_exact_real_redelivery_can_backfill() -> Result<()>
{
    let tmp = tempfile::tempdir()?;
    let path = tmp.path().join("db");
    let j = Journal::open(&path, IDENTITY).await?;
    j.claim("chat:old", &frame("old", "conv")).await?;
    j.finish("chat:old",&json!({"version":1,"type":"message.reply","message_id":"final-old","reply_to":"old","conversation_id":"conv","content":"done"})).await?;
    j.shutdown().await?;
    drop(j);
    let db = rusqlite::Connection::open(&path)?;
    db.execute("DELETE FROM chat_input_provenance", [])?;
    drop(db);
    let j = Journal::open(&path, IDENTITY).await?;
    assert!(j.proven_chat_anchor("old", "conv").await?.is_none());
    j.claim("chat:old", &frame("old", "conv")).await?;
    assert!(j.proven_chat_anchor("old", "conv").await?.is_some());
    j.shutdown().await?;
    Ok(())
}
