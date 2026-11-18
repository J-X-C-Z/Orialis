use super::*;
use crate::interactions::FeatureEmitter;
use tokio::sync::mpsc;

struct Emitter(mpsc::Sender<Value>);
impl FeatureEmitter for Emitter {
    fn emit<'a>(&'a self, frame: Value) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            self.0.send(frame).await?;
            Ok(())
        })
    }
}
fn context() -> TurnContext {
    TurnContext {
        conversation_id: "conversation".into(),
        session_id: "session".into(),
        input_id: "input".into(),
    }
}
async fn setup(
    permission: Permission,
    hub: Option<InteractionHub>,
    capacity: usize,
) -> Result<(tempfile::TempDir, LocalTools)> {
    let dir = tempfile::tempdir()?;
    fs::create_dir(dir.path().join("root"))?;
    let mut cfg = LocalToolsConfig::new(
        "owner".into(),
        dir.path().join("root"),
        dir.path().join("state.sqlite"),
    );
    cfg.write = permission;
    cfg.max_session_routes = capacity;
    Ok((dir, LocalTools::open(cfg, hub, None).await?))
}
async fn request(rx: &mut mpsc::Receiver<Value>) -> Result<Value> {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = rx.recv().await.context("approval emitter closed")?;
            if frame["type"] == "approval.request" {
                return Ok(frame);
            }
        }
    })
    .await?
}
async fn approve(hub: &InteractionHub, frame: &Value) -> Result<()> {
    hub.resolve(&json!({"type":"approval.resolve","request_id":frame["request_id"],"conversation_id":frame["conversation_id"],"decision":"once"})).await?;
    Ok(())
}

#[tokio::test]
async fn snapshots_and_partial_windows_do_not_cross_generations() -> Result<()> {
    let (dir, tools) = setup(Permission::Allow, None, 2).await?;
    fs::write(dir.path().join("root/a"), "a\nb\n")?;
    let ctx = context();
    tools
        .execute_at_generation("read_file", json!({"path":"a"}), &ctx, 0)
        .await?;
    tools.set_session_generation("session", 1).await?;
    assert!(
        tools
            .execute_at_generation("write_file", json!({"path":"a","content":"bad"}), &ctx, 1)
            .await
            .is_err()
    );
    tools
        .execute_at_generation("read_file", json!({"path":"a","limit":1}), &ctx, 1)
        .await?;
    tools.set_session_generation("session", 2).await?;
    let partial = tools
        .execute_at_generation("read_file", json!({"path":"a","offset":2}), &ctx, 2)
        .await?;
    assert_eq!(partial["complete_read"], false);
    assert!(
        tools
            .execute_at_generation("write_file", json!({"path":"a","content":"bad"}), &ctx, 2)
            .await
            .is_err()
    );
    tools
        .execute_at_generation("read_file", json!({"path":"a"}), &ctx, 2)
        .await?;
    tools
        .execute_at_generation("write_file", json!({"path":"a","content":"good"}), &ctx, 2)
        .await?;
    assert_eq!(fs::read_to_string(dir.path().join("root/a"))?, "good");
    Ok(())
}

#[tokio::test]
async fn direct_execute_captures_current_epoch_without_old_read_authority() -> Result<()> {
    let (dir, tools) = setup(Permission::Allow, None, 2).await?;
    fs::write(dir.path().join("root/a"), "before")?;
    let ctx = context();
    tools
        .execute("read_file", json!({"path":"a"}), &ctx)
        .await?;
    tools.set_session_generation("session", 1).await?;
    assert!(
        tools
            .execute("write_file", json!({"path":"a","content":"bad"}), &ctx)
            .await
            .is_err()
    );
    tools
        .execute("read_file", json!({"path":"a"}), &ctx)
        .await?;
    tools
        .execute("write_file", json!({"path":"a","content":"after"}), &ctx)
        .await?;
    assert_eq!(fs::read_to_string(dir.path().join("root/a"))?, "after");
    Ok(())
}

#[tokio::test]
async fn pending_native_approvals_cannot_cross_reset() -> Result<()> {
    for (name, arguments) in [
        ("write_file", json!({"path":"new","content":"bad"})),
        (
            "todo_list",
            json!({"todos":[{"id":"a","content":"bad","status":"pending"}]}),
        ),
        (
            "skill_manage",
            json!({"operations":[{"action":"create","name":"new-skill","content":"---\nname: new-skill\ndescription: Test skill\n---\n# Skill\n"}]}),
        ),
    ] {
        let (tx, mut rx) = mpsc::channel(16);
        let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(3))?;
        let (dir, tools) = setup(Permission::Ask, Some(hub.clone()), 2).await?;
        let worker = tools.clone();
        let job = tokio::spawn(async move {
            worker
                .execute_call_at_generation(name, arguments, &context(), 0, "native-call")
                .await
        });
        let frame = request(&mut rx).await?;
        tools.set_session_generation("session", 1).await?;
        approve(&hub, &frame).await?;
        assert!(job.await?.is_err(), "{name} accepted stale approval");
        assert!(!dir.path().join("root/new").exists());
        let count: usize = tools.inner.db.lock().unwrap().query_row(
            "SELECT count(*) FROM local_skills",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(count, 0);
    }
    Ok(())
}

#[tokio::test]
async fn reset_publishes_before_cooperative_commit_barrier() -> Result<()> {
    let (_dir, tools) = setup(Permission::Allow, None, 2).await?;
    let ctx = context();
    let execution = LocalExecution::new(&ctx, 0, "call".into())?;
    let action = json!({"exact":"action"});
    let mut grant = LOCAL_EXECUTION
        .scope(
            execution,
            tools.authorize(Permission::Allow, &ctx, &action, "effect"),
        )
        .await?;
    let resetting = tools.clone();
    let job = tokio::spawn(async move { resetting.set_session_generation("session", 1).await });
    tokio::time::timeout(Duration::from_secs(2), async {
        while tools.inner.python.current_generation("session").unwrap() == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await?;
    assert!(
        !job.is_finished(),
        "reset must await preexisting effect lease cooperatively"
    );
    assert!(grant.verify(&ctx, &action).is_err());
    drop(grant);
    job.await??;
    Ok(())
}

#[tokio::test]
async fn cancelled_execution_is_fenced_inside_blocking_worker() -> Result<()> {
    let (_dir, tools) = setup(Permission::Allow, None, 2).await?;
    let ctx = context();
    let execution = LocalExecution::new(&ctx, 0, "call".into())?;
    let retirement = RetireExecution(execution.retired.clone());
    let action = json!({"exact":"action"});
    let mut grant = LOCAL_EXECUTION
        .scope(
            execution,
            tools.authorize(Permission::Allow, &ctx, &action, "effect"),
        )
        .await?;
    drop(retirement);
    tokio::task::spawn_blocking(move || assert!(grant.verify(&ctx, &action).is_err())).await?;
    Ok(())
}

#[tokio::test]
async fn stop_revokes_only_matching_conversation_pending_approval() -> Result<()> {
    let (tx, mut rx) = mpsc::channel(16);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(3))?;
    let (dir, tools) = setup(Permission::Ask, Some(hub.clone()), 2).await?;
    let worker = tools.clone();
    let first = tokio::spawn(async move {
        worker
            .execute_at_generation(
                "write_file",
                json!({"path":"stopped","content":"bad"}),
                &context(),
                0,
            )
            .await
    });
    let stopped = request(&mut rx).await?;
    let worker = tools.clone();
    let second = tokio::spawn(async move {
        let mut ctx = context();
        ctx.conversation_id = "other".into();
        ctx.session_id = "other-session".into();
        worker
            .execute_at_generation(
                "write_file",
                json!({"path":"allowed","content":"good"}),
                &ctx,
                0,
            )
            .await
    });
    let allowed = request(&mut rx).await?;
    tools.cancel_conversation("conversation").await;
    assert!(first.await?.is_err());
    assert!(approve(&hub, &stopped).await.is_err());
    approve(&hub, &allowed).await?;
    second.await??;
    assert!(!dir.path().join("root/stopped").exists());
    assert_eq!(fs::read_to_string(dir.path().join("root/allowed"))?, "good");
    Ok(())
}

#[tokio::test]
async fn registry_overflow_fails_closed_for_non_python_tools() -> Result<()> {
    let (_dir, tools) = setup(Permission::Allow, None, 1).await?;
    tools.set_session_generation("known", 1).await?;
    assert!(tools.set_session_generation("session", 1).await.is_err());
    assert!(
        tools
            .execute_at_generation("todo_list", json!({}), &context(), 0)
            .await
            .is_err()
    );
    assert!(
        tools
            .execute("todo_list", json!({}), &context())
            .await
            .is_err()
    );
    let mut known = context();
    known.session_id = "known".into();
    tools
        .execute_at_generation("todo_list", json!({}), &known, 1)
        .await?;
    tools.set_session_generation("known", 2).await?;
    tools.set_session_generation("known", 1).await?;
    assert!(
        tools
            .execute_at_generation("todo_list", json!({}), &known, 1)
            .await
            .is_err()
    );
    Ok(())
}

#[tokio::test]
async fn aborting_actual_execution_before_blocking_commit_prevents_late_write() -> Result<()> {
    for existing in [false, true] {
        let (tx, mut rx) = mpsc::channel(16);
        let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(3))?;
        let (dir, tools) = setup(Permission::Ask, Some(hub.clone()), 2).await?;
        let path = dir.path().join("root/target");
        if existing {
            fs::write(&path, "original bytes\n")?;
            tools
                .execute_at_generation("read_file", json!({"path":"target"}), &context(), 0)
                .await?;
        }
        let worker = tools.clone();
        let execution = tokio::spawn(async move {
            worker
                .execute_call_at_generation(
                    "write_file",
                    json!({"path":"target","content":"must never appear\n"}),
                    &context(),
                    0,
                    "abort-before-commit",
                )
                .await
        });
        // Approval is emitted only after write planning released mutation.
        let frame = request(&mut rx).await?;
        let inner = tools.inner.clone();
        let (locked, ready) = tokio::sync::oneshot::channel();
        let (release, released) = std::sync::mpsc::channel();
        let holder = tokio::task::spawn_blocking(move || {
            let _mutation = inner.mutation.lock().unwrap();
            let _ = locked.send(());
            let _ = released.recv();
        });
        ready.await?;
        approve(&hub, &frame).await?;
        // This is an actual granted tool call, queued in spawn_blocking behind
        // mutation, not a synthetic grant or manually flipped retirement flag.
        tokio::time::timeout(Duration::from_secs(2), async {
            while tools.inner.effects.try_write().is_ok() {
                tokio::task::yield_now().await;
            }
        })
        .await?;
        execution.abort();
        assert!(execution.await.unwrap_err().is_cancelled());
        // Release the queued blocking commit after the outer execution future
        // has certainly dropped. Join the holder, then drain the effect lease
        // to prove the detached worker has finished before inspecting bytes.
        release.send(())?;
        holder.await?;
        let _drained =
            tokio::time::timeout(Duration::from_secs(2), tools.inner.effects.write()).await?;
        if existing {
            assert_eq!(fs::read_to_string(&path)?, "original bytes\n");
        } else {
            assert!(!path.exists());
        }
        let entries =
            fs::read_dir(dir.path().join("root"))?.collect::<std::io::Result<Vec<_>>>()?;
        assert_eq!(
            entries.len(),
            usize::from(existing),
            "no temporary or partial write may remain"
        );
    }
    Ok(())
}
