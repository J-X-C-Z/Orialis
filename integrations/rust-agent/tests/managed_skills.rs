#![cfg(unix)]
use anyhow::Result;
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    Store,
    interactions::{FeatureEmitter, InteractionHub},
    local_tools::{LocalTools, LocalToolsConfig, Permission},
    profile_bridge::{BridgeConfig, ManagedSkillsConfig, ProfileBridge},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use std::{fs, path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::mpsc;
fn context() -> TurnContext {
    TurnContext {
        conversation_id: "chat".into(),
        input_id: "input".into(),
        session_id: "session".into(),
    }
}
fn body(name: &str) -> String {
    format!("---\nname: {name}\ndescription: Useful safe test skill\n---\nUse careful examples.\n")
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    state: PathBuf,
    tools: LocalTools,
}
impl Fixture {
    async fn new(permission: Permission, hub: Option<InteractionHub>) -> Result<Self> {
        let temp = tempfile::tempdir()?;
        let root = temp.path().join("profile");
        fs::create_dir(&root)?;
        fs::create_dir(root.join("skills"))?;
        let state = temp.path().join("local.sqlite");
        let mut cfg = LocalToolsConfig::new("alice".into(), root.clone(), state.clone());
        cfg.write = permission;
        cfg.skills_root = Some("skills".into());
        let tools = LocalTools::open(cfg, hub, None).await?;
        Ok(Self {
            _temp: temp,
            root,
            state,
            tools,
        })
    }
    async fn ops(&self, ops: Value) -> Result<Value> {
        self.tools
            .execute("skill_manage", json!({"operations":ops}), &context())
            .await
    }
    async fn create(&self, name: &str) -> Result<()> {
        self.ops(json!([{"action":"create","name":name,"content":body(name)},{"action":"write_file","name":name,"file_path":"references/a.txt","file_content":"alpha"}])).await?;
        Ok(())
    }
    async fn view(&self, name: &str, path: &str) -> Result<Value> {
        self.tools
            .execute(
                "skill_view",
                json!({"name":name,"file_path":path}),
                &context(),
            )
            .await
    }
}
#[tokio::test]
async fn remove_file_delete_absorption_and_restart_are_durable() -> Result<()> {
    let f = Fixture::new(Permission::Allow, None).await?;
    f.create("one").await?;
    f.create("two").await?;
    f.ops(json!([{"action":"remove_file","name":"one","file_path":"references/a.txt"}]))
        .await?;
    assert!(f.view("one", "references/a.txt").await.is_err());
    assert!(f.view("one", "SKILL.md").await.is_ok());
    for target in ["one", "missing"] {
        assert!(
            f.ops(json!([{"action":"delete","name":"one","absorbed_into":target}]))
                .await
                .is_err()
        );
    }
    assert!(
        f.ops(json!([{"action":"delete","name":"one","absorbed_into":false}]))
            .await
            .is_err()
    );
    f.ops(json!([{"action":"delete","name":"one","absorbed_into":" two "}]))
        .await?;
    assert!(f.view("one", "SKILL.md").await.is_err());
    assert!(f.view("two", "references/a.txt").await.is_ok());
    let db = hermes_rust_core::private_db::open_private(&f.state)?;
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM local_skills WHERE name='one'",
            [],
            |r| r.get::<_, usize>(0)
        )?,
        0
    );
    drop(db);
    let Fixture {
        _temp,
        root,
        state,
        tools,
    } = f;
    drop(tools);
    let mut cfg = LocalToolsConfig::new("alice".into(), root, state);
    cfg.write = Permission::Allow;
    let reopened = LocalTools::open(cfg, None, None).await?;
    assert_eq!(
        reopened
            .execute("skills_list", json!({}), &context())
            .await?["skills"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    Ok(())
}
#[tokio::test]
async fn whole_batch_preflight_clobber_path_and_schema_guards() -> Result<()> {
    let f = Fixture::new(Permission::Allow, None).await?;
    f.create("one").await?;
    for path in [
        "SKILL.md",
        "../outside",
        "/tmp/outside",
        "references/../SKILL.md",
        "references",
        "unknown/a",
    ] {
        assert!(
            f.ops(json!([{"action":"remove_file","name":"one","file_path":path}]))
                .await
                .is_err(),
            "{path}"
        );
    }
    let batches = [
        json!([{"action":"delete","name":"one"},{"action":"create","name":"two","content":body("two")}]),
        json!([{"action":"patch","name":"one","file_path":"references/a.txt","old_string":"alpha","new_string":"beta"},{"action":"remove_file","name":"one","file_path":"references/./a.txt"}]),
        json!([{"action":"remove_file","name":"one","file_path":"references/a.txt"},{"action":"remove_file","name":"one","file_path":"references/missing"}]),
        json!([{"action":"remove_file","name":"one","file_path":"references/a.txt","content":"wrong slot"}]),
    ];
    for batch in batches {
        assert!(f.ops(batch).await.is_err());
        assert_eq!(f.view("one", "references/a.txt").await?["content"], "alpha");
    }
    let too_many = (0..21)
        .map(|i| json!({"action":"create","name":format!("new-{i}"),"content":body("new")}))
        .collect::<Vec<_>>();
    assert!(f.ops(json!(too_many)).await.is_err());
    f.ops(json!([{"action":"write_file","name":"one","file_path":"references/a.txt","file_content":"beta"},{"action":"patch","name":"one","file_path":"references/a.txt","old_string":"beta","new_string":"gamma"}])).await?;
    assert_eq!(f.view("one", "references/a.txt").await?["content"], "gamma");
    let schema = f
        .tools
        .schemas()
        .into_iter()
        .find(|v| v["function"]["name"] == "skill_manage")
        .unwrap();
    let validator = jsonschema::validator_for(&schema["function"]["parameters"])?;
    assert!(validator.is_valid(&json!({"operations":[{"action":"delete","name":"one"}]})));
    assert!(!validator.is_valid(&json!({"operations":[{"action":"remove_file","name":"one","file_path":"references/a.txt","content":"wrong slot"}]})));
    Ok(())
}
#[tokio::test]
async fn configured_and_other_owner_skills_cannot_be_deleted() -> Result<()> {
    let f = Fixture::new(Permission::Allow, None).await?;
    fs::create_dir(f.root.join("skills/disk"))?;
    fs::write(f.root.join("skills/disk/SKILL.md"), body("disk"))?;
    for action in ["delete", "remove_file"] {
        assert!(
            f.ops(json!([{"action":action,"name":"disk","file_path":"references/a.txt"}]))
                .await
                .is_err()
        );
    }
    assert!(f.root.join("skills/disk/SKILL.md").exists());
    f.create("one").await?;
    f.ops(json!([{"action":"delete","name":"one","absorbed_into":"disk"}]))
        .await?;
    let mut cfg = LocalToolsConfig::new("mallory".into(), f.root.clone(), f.state.clone());
    cfg.write = Permission::Allow;
    assert!(LocalTools::open(cfg, None, None).await.is_err());
    Ok(())
}
struct Emitter(mpsc::Sender<Value>);
impl FeatureEmitter for Emitter {
    fn emit<'a>(&'a self, v: Value) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            self.0.send(v).await?;
            Ok(())
        })
    }
}
#[tokio::test]
async fn removal_needs_exact_approval_and_stale_batch_cannot_commit() -> Result<()> {
    let (tx, mut rx) = mpsc::channel(32);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(2))?;
    let f = Fixture::new(Permission::Ask, Some(hub.clone())).await?;
    // Seed only synthetic fixture rows, not by bypassing a denied model action.
    let db = hermes_rust_core::private_db::open_private(&f.state)?;
    db.execute(
        "INSERT INTO local_skills VALUES('one','SKILL.md',?1)",
        [body("one")],
    )?;
    db.execute(
        "INSERT INTO local_skills VALUES('one','references/a.txt','alpha')",
        [],
    )?;
    for decision in ["deny", "once"] {
        let tools = f.tools.clone();
        let task = tokio::spawn(async move {
            tools.execute("skill_manage",json!({"operations":[{"action":"remove_file","name":"one","file_path":"references/a.txt"}]}),&context()).await
        });
        let request = loop {
            let frame = tokio::time::timeout(Duration::from_secs(3), rx.recv())
                .await?
                .unwrap();
            if frame["type"] == "approval.request" {
                break frame;
            }
        };
        if decision == "once" {
            db.execute(
                "UPDATE local_skills SET body='external' WHERE path='references/a.txt'",
                [],
            )?;
        }
        hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"chat","decision":decision})).await?;
        assert!(task.await?.is_err());
        assert!(f.view("one", "references/a.txt").await.is_ok());
    }
    Ok(())
}
#[tokio::test]
async fn deleted_managed_files_export_without_resurrection() -> Result<()> {
    let f = Fixture::new(Permission::Allow, None).await?;
    f.create("one").await?;
    let mut store = Store::open(&f._temp.path().join("core.sqlite"))?;
    let bridge = ProfileBridge::new(BridgeConfig {
        owner: "alice".into(),
        source_id: "test".into(),
        profile: f.root.clone(),
        managed_skills: Some(ManagedSkillsConfig {
            database: f.state.clone(),
            workspace_root: f.root.clone(),
            skills_root: "skills".into(),
            names: vec!["one".into()],
        }),
    })?;
    assert!(store.reconcile_profile(&bridge)?.ready_for_sync());
    assert!(f.root.join("skills/one/references/a.txt").exists());
    f.ops(json!([{"action":"remove_file","name":"one","file_path":"references/a.txt"}]))
        .await?;
    assert!(f.view("one", "references/a.txt").await.is_err());
    assert!(store.reconcile_profile(&bridge)?.ready_for_sync());
    assert!(!f.root.join("skills/one/references/a.txt").exists());
    f.ops(json!([{"action":"delete","name":"one"}])).await?;
    assert!(f.view("one", "SKILL.md").await.is_err());
    assert!(
        f.tools
            .execute("skills_list", json!({}), &context())
            .await?["skills"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(store.reconcile_profile(&bridge)?.ready_for_sync());
    assert!(!f.root.join("skills/one/SKILL.md").exists());
    assert!(store.reconcile_profile(&bridge)?.ready_for_sync());
    assert!(f.view("one", "SKILL.md").await.is_err());
    Ok(())
}

#[tokio::test]
async fn incremental_commit_writes_only_changed_rows() -> Result<()> {
    let f = Fixture::new(Permission::Allow, None).await?;
    f.create("one").await?;
    f.create("two").await?;
    let db = hermes_rust_core::private_db::open_private(&f.state)?;
    db.execute_batch("CREATE TABLE mutation_log(kind TEXT); CREATE TRIGGER log_insert AFTER INSERT ON local_skills BEGIN INSERT INTO mutation_log VALUES('insert'); END; CREATE TRIGGER log_update AFTER UPDATE ON local_skills BEGIN INSERT INTO mutation_log VALUES('update'); END; CREATE TRIGGER log_delete AFTER DELETE ON local_skills BEGIN INSERT INTO mutation_log VALUES('delete'); END;")?;
    f.ops(json!([{"action":"patch","name":"one","file_path":"references/a.txt","old_string":"alpha","new_string":"beta"}])).await?;
    assert_eq!(
        db.query_row("SELECT group_concat(kind) FROM mutation_log", [], |r| {
            r.get::<_, String>(0)
        })?,
        "update"
    );
    db.execute("DELETE FROM mutation_log", [])?;
    f.ops(json!([{"action":"delete","name":"one"}])).await?;
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM mutation_log WHERE kind='delete'",
            [],
            |r| r.get::<_, usize>(0)
        )?,
        2
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM mutation_log WHERE kind!='delete'",
            [],
            |r| r.get::<_, usize>(0)
        )?,
        0
    );
    assert_eq!(f.view("two", "references/a.txt").await?["content"], "alpha");
    Ok(())
}

#[tokio::test]
async fn deletion_marker_capacity_fails_closed_and_recreation_clears_marker() -> Result<()> {
    let f = Fixture::new(Permission::Allow, None).await?;
    f.create("one").await?;
    let db = hermes_rust_core::private_db::open_private(&f.state)?;
    db.execute_batch("WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<9999) INSERT INTO local_skill_tombstones SELECT 'deleted-'||x FROM n;")?;
    let error = f
        .ops(json!([{"action":"delete","name":"one"}]))
        .await
        .unwrap_err();
    assert!(error.to_string().contains("capacity"), "{error:#}");
    assert!(f.view("one", "SKILL.md").await.is_ok());
    // Recreating an existing tombstoned name frees exactly that marker.
    f.create("deleted-0").await?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM local_skill_tombstones", [], |r| r
            .get::<_, usize>(
            0
        ))?,
        9999
    );
    f.ops(json!([{"action":"delete","name":"one"}])).await?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM local_skill_tombstones", [], |r| r
            .get::<_, usize>(
            0
        ))?,
        10000
    );
    assert!(f.view("one", "SKILL.md").await.is_err());
    Ok(())
}
