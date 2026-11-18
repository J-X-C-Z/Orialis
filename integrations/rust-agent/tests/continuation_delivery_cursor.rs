use hermes_rust_core::delivery::{
    DeliveryBody, DeliveryIdentity, DeliveryKind, DeliveryLimits, DeliveryOutbox, DeliveryRequest,
    DeliveryTarget,
};

#[tokio::test]
async fn stable_delivery_cursor_skips_blocked_prefix_and_survives_removal() -> anyhow::Result<()> {
    let dir = tempfile::tempdir()?;
    let identity = DeliveryIdentity::new(
        "owner",
        "ws://127.0.0.1:12345/api/v1/agent/ws",
        "Test_Device",
        "fixture-token",
    )?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("outbox.sqlite"),
        identity.clone(),
        DeliveryLimits::default(),
    )
    .await?;
    for n in (0..40).rev() {
        outbox
            .enqueue(DeliveryRequest {
                delivery_id: format!("output-{n:03}"),
                target: DeliveryTarget {
                    owner: identity.owner.clone(),
                    device_id: identity.device_id.clone(),
                    conversation_id: format!("chat-{n}"),
                },
                kind: DeliveryKind::Proactive,
                body: DeliveryBody::text(format!("final-{n}")),
            })
            .await?;
    }
    // Existing callers retain insertion order; the new lane is stable key order.
    assert_eq!(
        outbox.pending(1).await?[0].request.delivery_id,
        "output-039"
    );
    let first = outbox.pending_after(None, 32).await?;
    assert_eq!(first.len(), 32);
    assert_eq!(first[0].request.delivery_id, "output-000");
    let last = first.last().unwrap().request.delivery_id.clone();
    outbox.cancel(&last).await?;
    let second = outbox.pending_after(Some(&last), 32).await?;
    assert_eq!(second.len(), 8);
    assert_eq!(second.last().unwrap().request.delivery_id, "output-039");
    // Wrapping still discovers a lower-ID item admitted during the scan.
    outbox
        .enqueue(DeliveryRequest {
            delivery_id: "aaa-new".into(),
            target: DeliveryTarget {
                owner: identity.owner,
                device_id: identity.device_id,
                conversation_id: "chat-new".into(),
            },
            kind: DeliveryKind::Proactive,
            body: DeliveryBody::text("new"),
        })
        .await?;
    assert_eq!(
        outbox.pending_after(None, 1).await?[0].request.delivery_id,
        "aaa-new"
    );
    assert!(outbox.pending_after(None, 0).await.is_err());
    Ok(())
}
