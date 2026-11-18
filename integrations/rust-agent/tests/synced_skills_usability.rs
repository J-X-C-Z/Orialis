#![cfg(unix)]
//! Actual local catalog calls after portable profile reconciliation and hub sync.
//! Synthetic data only. A synced script is readable data, never execution authority.
use anyhow::Result;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use hermes_rust_core::{
    Store,
    local_tools::{LocalTools, LocalToolsConfig, Permission},
    profile_bridge::{BridgeConfig, ManagedSkillsConfig, ProfileBridge},
    profile_sync::{self, SyncConfig},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use std::{fs, path::Path};

const KEY: &str = "engineering/review";
const BODY: &str = "---\nname: review-alias\ndescription: Review a portable example.\n---\nRead references/checklist.md before answering.\n";
const BINARY: &[u8] = b"\x89PNG\r\n\x1a\n\0\xffportable-resource";

fn context() -> TurnContext {
    TurnContext {
        conversation_id: "portable-skill-chat".into(),
        input_id: "portable-skill-input".into(),
        session_id: "portable-skill-session".into(),
    }
}

struct Device {
    root: tempfile::TempDir,
    tools: LocalTools,
    bridge: ProfileBridge,
    store: Store,
}
impl Device {
    async fn new(managed: bool) -> Result<Self> {
        let root = tempfile::tempdir()?;
        let profile = root.path().join("profile");
        fs::create_dir_all(profile.join("skills"))?;
        let database = root.path().join("local.sqlite");
        let mut cfg = LocalToolsConfig::new("alice".into(), profile.clone(), database.clone());
        cfg.skills_root = Some("skills".into());
        cfg.write = Permission::Allow;
        cfg.execute = Permission::Deny;
        let tools = LocalTools::open(cfg, None, None).await?;
        let bridge = ProfileBridge::new(BridgeConfig {
            owner: "alice".into(),
            source_id: "portable-usability".into(),
            profile: profile.clone(),
            managed_skills: managed.then(|| ManagedSkillsConfig {
                database,
                workspace_root: profile,
                skills_root: "skills".into(),
                names: vec![KEY.into()],
            }),
        })?;
        let store = Store::open(&root.path().join("core.sqlite"))?;
        Ok(Self {
            root,
            tools,
            bridge,
            store,
        })
    }
    fn write(&self, path: &str, content: &[u8]) -> Result<()> {
        let path = self.root.path().join("profile").join(path);
        fs::create_dir_all(path.parent().unwrap())?;
        fs::write(path, content)?;
        Ok(())
    }
    fn reconcile(&mut self) -> Result<()> {
        let report = self.store.reconcile_profile(&self.bridge)?;
        assert!(
            report.ready_for_sync(),
            "portable profile was not ready: {report:?}"
        );
        Ok(())
    }
    fn sync(&mut self, hub: &Path, node: &str) -> Result<()> {
        let outcome = self.exchange(hub, node)?;
        assert!(outcome.conflicts.is_empty(), "{outcome:?}");
        Ok(())
    }
    fn exchange(&mut self, hub: &Path, node: &str) -> Result<profile_sync::SyncOutcome> {
        self.reconcile()?;
        let outcome = profile_sync::run_sync(&SyncConfig {
            profile: self.root.path().join("profile"),
            state_dir: self.root.path().join("sync"),
            node: node.into(),
            hub_store: Some(hub.to_owned()),
            ssh: vec![],
            force_payload: false,
            allowed_skill_roots: vec![],
        })?;
        self.reconcile()?;
        Ok(outcome)
    }
    async fn call(&self, name: &str, args: Value) -> Result<Value> {
        self.tools.execute(name, args, &context()).await
    }
    async fn restart(self) -> Result<Self> {
        let Self {
            root,
            tools,
            bridge,
            store,
        } = self;
        drop(tools);
        drop(store);
        let mut cfg = LocalToolsConfig::new(
            "alice".into(),
            root.path().join("profile"),
            root.path().join("local.sqlite"),
        );
        cfg.skills_root = Some("skills".into());
        cfg.write = Permission::Allow;
        cfg.execute = Permission::Deny;
        let tools = LocalTools::open(cfg, None, None).await?;
        let store = Store::open(&root.path().join("core.sqlite"))?;
        Ok(Self {
            root,
            tools,
            bridge,
            store,
        })
    }
}

#[tokio::test]
async fn configured_binary_resource_is_readable_after_cross_device_sync() -> Result<()> {
    let hub = tempfile::tempdir()?;
    let mut a = Device::new(false).await?;
    let mut b = Device::new(false).await?;
    a.write(&format!("skills/{KEY}/SKILL.md"), BODY.as_bytes())?;
    a.write(&format!("skills/{KEY}/assets/image.png"), BINARY)?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    let main = b.call("skill_view", json!({"name":"review-alias"})).await?;
    assert_eq!(main["linked_files"]["assets"], json!(["assets/image.png"]));
    let resource = b
        .call(
            "skill_view",
            json!({"name":"review-alias", "file_path":"assets/image.png"}),
        )
        .await?;
    assert_eq!(resource["content_encoding"], "base64");
    assert_eq!(
        STANDARD.decode(resource["content_base64"].as_str().unwrap())?,
        BINARY
    );
    assert_eq!(resource["byte_count"], BINARY.len());
    assert_eq!(resource["sha256"], profile_sync::digest(BINARY));
    assert_eq!(resource["content"], Value::Null);
    assert_eq!(resource["activation"], "disabled");
    assert_eq!(resource["content_trust"], "untrusted_skill_data");
    assert_eq!(resource["read_only"], true);
    Ok(())
}

#[tokio::test]
async fn selected_managed_binary_resource_does_not_block_profile_sync() -> Result<()> {
    let hub = tempfile::tempdir()?;
    let mut a = Device::new(true).await?;
    let mut b = Device::new(true).await?;
    a.write(&format!("skills/{KEY}/SKILL.md"), BODY.as_bytes())?;
    a.write(&format!("skills/{KEY}/assets/image.png"), BINARY)?;
    a.write(
        &format!("skills/{KEY}/assets/nul.bin"),
        b"valid-utf8\0still-binary",
    )?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    for (path, expected) in [
        ("assets/image.png", BINARY),
        ("assets/nul.bin", &b"valid-utf8\0still-binary"[..]),
    ] {
        let view = b
            .call(
                "skill_view",
                json!({"name":"review-alias","file_path":path}),
            )
            .await?;
        assert_eq!(view["source"], "managed_store");
        assert_eq!(view["content"], Value::Null);
        assert_eq!(
            STANDARD.decode(view["content_base64"].as_str().unwrap())?,
            expected
        );
    }
    let db = hermes_rust_core::private_db::open_private(&b.root.path().join("local.sqlite"))?;
    assert_eq!(
        db.query_row(
            "SELECT typeof(body) FROM local_skills WHERE name=?1 AND path='SKILL.md'",
            [KEY],
            |r| r.get::<_, String>(0)
        )?,
        "text"
    );
    assert_eq!(
        db.query_row(
            "SELECT typeof(body) FROM local_skills WHERE name=?1 AND path='assets/image.png'",
            [KEY],
            |r| r.get::<_, String>(0)
        )?,
        "blob"
    );
    drop(db);
    b = b.restart().await?;
    b.reconcile()?;
    let view = b
        .call(
            "skill_view",
            json!({"name":"review","file_path":"assets/image.png"}),
        )
        .await?;
    assert_eq!(
        STANDARD.decode(view["content_base64"].as_str().unwrap())?,
        BINARY
    );
    // Updating text does not decode or discard unrelated opaque rows.
    b.call("skill_manage", json!({"operations":[{"action":"patch","name":KEY,"old_string":"before answering","new_string":"before a careful answer"}]})).await?;
    b.sync(hub.path(), "b")?;
    a.sync(hub.path(), "a")?;
    assert_eq!(
        fs::read(
            a.root
                .path()
                .join(format!("profile/skills/{KEY}/assets/image.png"))
        )?,
        BINARY
    );
    a.call(
        "skill_manage",
        json!({"operations":[{"action":"remove_file","name":KEY,"file_path":"assets/nul.bin"}]}),
    )
    .await?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    assert!(
        b.call(
            "skill_view",
            json!({"name":"review-alias","file_path":"assets/nul.bin"})
        )
        .await
        .is_err()
    );
    a.call(
        "skill_manage",
        json!({"operations":[{"action":"delete","name":KEY}]}),
    )
    .await?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    b = b.restart().await?;
    assert_eq!(b.call("skills_list", json!({})).await?["count"], 0);
    assert!(
        !b.root
            .path()
            .join(format!("profile/skills/{KEY}/assets/image.png"))
            .exists()
    );
    let db = hermes_rust_core::private_db::open_private(&b.root.path().join("local.sqlite"))?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM local_skills", [], |r| r
            .get::<_, usize>(0))?,
        0
    );
    Ok(())
}

#[tokio::test]
async fn managed_binary_patch_stale_read_and_conflict_do_not_lose_bytes() -> Result<()> {
    let mut a = Device::new(true).await?;
    a.write(&format!("skills/{KEY}/SKILL.md"), BODY.as_bytes())?;
    a.write(&format!("skills/{KEY}/assets/image.png"), BINARY)?;
    a.reconcile()?;
    assert!(a.call("skill_manage", json!({"operations":[{"action":"patch","name":KEY,"file_path":"assets/image.png","old_string":"portable","new_string":"changed"}]})).await.is_err());
    assert!(a.call("skill_manage", json!({"operations":[{"action":"patch","name":KEY,"file_path":"assets/image.png","content":"explicit text replacement"}]})).await.is_err());
    assert!(a.call("skill_manage", json!({"operations":[{"action":"write_file","name":KEY,"file_path":"assets/image.png","file_content":"explicit text replacement"}]})).await.is_err());
    a.call(
        "skill_view",
        json!({"name":"review-alias","file_path":"assets/image.png"}),
    )
    .await?;
    let changed = b"\0\xffnew-portable-bytes";
    a.write(&format!("skills/{KEY}/assets/image.png"), changed)?;
    a.reconcile()?;
    let stale = a.call("skill_manage", json!({"operations":[{"action":"patch","name":KEY,"file_path":"assets/image.png","content":"explicit text replacement"}]})).await.unwrap_err();
    assert!(stale.to_string().contains("changed since read"));
    assert!(a.call("skill_manage", json!({"operations":[{"action":"write_file","name":KEY,"file_path":"assets/image.png","file_content":"explicit text replacement"}]})).await.unwrap_err().to_string().contains("changed since read"));
    let view = a
        .call(
            "skill_view",
            json!({"name":"review-alias","file_path":"assets/image.png"}),
        )
        .await?;
    assert_eq!(
        STANDARD.decode(view["content_base64"].as_str().unwrap())?,
        changed
    );
    // Native and filesystem edits from one baseline conflict, preserve both,
    // and recover only when the operator deliberately reconciles their bytes.
    a.call("skill_manage", json!({"operations":[{"action":"patch","name":KEY,"file_path":"assets/image.png","content":"explicit text replacement"}]})).await?;
    a.write(
        &format!("skills/{KEY}/assets/image.png"),
        b"\0different filesystem edit",
    )?;
    let report = a.store.reconcile_profile(&a.bridge)?;
    assert_eq!(
        report.conflicts,
        vec![format!("skills/{KEY}/assets/image.png")]
    );
    assert!(report.quarantined.is_empty());
    assert_eq!(
        a.call(
            "skill_view",
            json!({"name":"review-alias","file_path":"assets/image.png"})
        )
        .await?["content"],
        "explicit text replacement"
    );
    a = a.restart().await?;
    assert_eq!(
        a.store.reconcile_profile(&a.bridge)?.conflicts,
        report.conflicts
    );
    assert_eq!(
        fs::read(
            a.root
                .path()
                .join(format!("profile/skills/{KEY}/assets/image.png"))
        )?,
        b"\0different filesystem edit"
    );
    a.write(
        &format!("skills/{KEY}/assets/image.png"),
        b"explicit text replacement",
    )?;
    a.reconcile()?;
    Ok(())
}

#[tokio::test]
async fn managed_binary_peer_conflict_preserves_versions_and_recovers_explicitly() -> Result<()> {
    let hub = tempfile::tempdir()?;
    let mut a = Device::new(true).await?;
    let mut b = Device::new(true).await?;
    let path = format!("skills/{KEY}/assets/image.png");
    a.write(&format!("skills/{KEY}/SKILL.md"), BODY.as_bytes())?;
    a.write(&path, BINARY)?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    let changed_a = b"\0device-A-resource";
    let changed_b = b"\0device-B-resource";
    a.write(&path, changed_a)?;
    b.write(&path, changed_b)?;
    a.sync(hub.path(), "a")?;
    let conflict = b.exchange(hub.path(), "b")?;
    assert_eq!(conflict.conflicts, vec![path.clone()]);
    assert_eq!(
        fs::read(b.root.path().join("profile").join(&path))?,
        changed_b
    );
    let view = b
        .call(
            "skill_view",
            json!({"name":"review-alias","file_path":"assets/image.png"}),
        )
        .await?;
    assert_eq!(
        STANDARD.decode(view["content_base64"].as_str().unwrap())?,
        changed_b
    );
    b = b.restart().await?;
    assert_eq!(b.exchange(hub.path(), "b")?.conflicts, conflict.conflicts);
    assert_eq!(
        fs::read(
            hub.path()
                .join("objects")
                .join(profile_sync::digest(changed_a))
        )?,
        changed_a
    );
    assert_eq!(
        fs::read(
            hub.path()
                .join("objects")
                .join(profile_sync::digest(changed_b))
        )?,
        changed_b
    );
    b.write(&path, changed_a)?;
    b.sync(hub.path(), "b")?;
    let view = b
        .call(
            "skill_view",
            json!({"name":"review-alias","file_path":"assets/image.png"}),
        )
        .await?;
    assert_eq!(
        STANDARD.decode(view["content_base64"].as_str().unwrap())?,
        changed_a
    );
    Ok(())
}

#[tokio::test]
async fn binary_inline_budget_omits_large_bytes_without_granting_rewrite() -> Result<()> {
    let hub = tempfile::tempdir()?;
    let mut a = Device::new(true).await?;
    let mut b = Device::new(true).await?;
    let small = vec![0; 8 * 1024];
    let large = vec![0xff; 128 * 1024];
    a.write(&format!("skills/{KEY}/SKILL.md"), BODY.as_bytes())?;
    a.write(&format!("skills/{KEY}/assets/small.bin"), &small)?;
    a.write(&format!("skills/{KEY}/assets/large.bin"), &large)?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    let view = b
        .call(
            "skill_view",
            json!({"name":"review","file_path":"assets/small.bin"}),
        )
        .await?;
    assert_eq!(view["complete_read"], true);
    assert_eq!(
        STANDARD.decode(view["content_base64"].as_str().unwrap())?,
        small
    );
    assert!(serde_json::to_vec(&view)?.len() < 16 * 1024);
    let view = b
        .call(
            "skill_view",
            json!({"name":"review","file_path":"assets/large.bin"}),
        )
        .await?;
    assert_eq!(view["content_omitted"], true);
    assert_eq!(view["complete_read"], false);
    assert_eq!(view["content_base64"], Value::Null);
    assert_eq!(view["sha256"], profile_sync::digest(&large));
    assert_eq!(view["byte_count"], large.len());
    assert!(serde_json::to_vec(&view)?.len() < 2048);
    assert_eq!(
        fs::read(
            b.root
                .path()
                .join(format!("profile/skills/{KEY}/assets/large.bin"))
        )?,
        large
    );
    for op in [
        json!({"action":"patch","name":KEY,"file_path":"assets/large.bin","content":"must not overwrite"}),
        json!({"action":"write_file","name":KEY,"file_path":"assets/large.bin","file_content":"must not overwrite"}),
    ] {
        assert!(
            b.call("skill_manage", json!({"operations":[op]}))
                .await
                .is_err()
        );
    }
    // An unrelated metadata-only view does not erase a legitimate small read.
    b.call("skill_manage", json!({"operations":[{"action":"patch","name":KEY,"file_path":"assets/small.bin","content":"explicit text replacement"}]})).await?;
    assert_eq!(
        b.call(
            "skill_view",
            json!({"name":"review","file_path":"assets/small.bin"})
        )
        .await?["content"],
        "explicit text replacement"
    );
    Ok(())
}

#[tokio::test]
async fn synced_managed_skill_catalog_alias_resources_update_and_delete_are_live() -> Result<()> {
    let hub = tempfile::tempdir()?;
    let mut a = Device::new(true).await?;
    let mut b = Device::new(true).await?;
    a.write(&format!("skills/{KEY}/SKILL.md"), BODY.as_bytes())?;
    a.write(
        &format!("skills/{KEY}/references/checklist.md"),
        b"Check the source, then answer.",
    )?;
    a.write(
        &format!("skills/{KEY}/scripts/do-not-run.sh"),
        b"#!/bin/sh\ntouch should-never-exist\n",
    )?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;

    let catalog = b
        .call("skills_list", json!({"category":"engineering"}))
        .await?;
    assert_eq!(catalog["count"], 1);
    assert_eq!(catalog["skills"][0]["name"], "review-alias");
    assert_eq!(catalog["skills"][0]["relative_path"], KEY);
    assert_eq!(catalog["skills"][0]["management_name"], KEY);
    assert_eq!(catalog["skills"][0]["source"], "managed_store");
    assert_eq!(catalog["categories"], json!(["engineering"]));
    for alias in ["review-alias", "review", KEY] {
        let main = b.call("skill_view", json!({"name":alias})).await?;
        assert_eq!(main["content"], BODY);
        assert_eq!(main["relative_path"], KEY);
        assert_eq!(
            main["linked_files"],
            json!({"references":["references/checklist.md"],"scripts":["scripts/do-not-run.sh"]})
        );
        assert_eq!(main["activation"], "disabled");
    }
    let reference = b
        .call(
            "skill_view",
            json!({"name":"review-alias","file_path":"references/checklist.md"}),
        )
        .await?;
    assert_eq!(reference["content"], "Check the source, then answer.");
    let script = b
        .call(
            "skill_view",
            json!({"name":"review","file_path":"scripts/do-not-run.sh"}),
        )
        .await?;
    assert_eq!(script["content"], "#!/bin/sh\ntouch should-never-exist\n");
    assert_eq!(script["activation"], "disabled");
    assert!(
        !b.tools
            .schemas()
            .iter()
            .any(|s| s["function"]["name"] == "terminal")
    );
    assert!(
        b.call(
            "terminal",
            json!({"program":"sh","args":["skills/engineering/review/scripts/do-not-run.sh"]})
        )
        .await
        .is_err()
    );
    assert!(!b.root.path().join("profile/should-never-exist").exists());

    a.call("skill_manage", json!({"operations":[
        {"action":"patch","name":KEY,"old_string":"review-alias","new_string":"updated-alias"},
        {"action":"patch","name":KEY,"file_path":"references/checklist.md","old_string":"source","new_string":"updated source"},
        {"action":"remove_file","name":KEY,"file_path":"scripts/do-not-run.sh"}
    ]})).await?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    assert!(
        b.call("skill_view", json!({"name":"review-alias"}))
            .await
            .is_err()
    );
    let updated = b
        .call("skill_view", json!({"name":"updated-alias"}))
        .await?;
    assert_eq!(
        updated["linked_files"],
        json!({"references":["references/checklist.md"]})
    );
    assert_eq!(
        b.call(
            "skill_view",
            json!({"name":"updated-alias","file_path":"references/checklist.md"})
        )
        .await?["content"],
        "Check the updated source, then answer."
    );
    assert!(
        b.call(
            "skill_view",
            json!({"name":"updated-alias","file_path":"scripts/do-not-run.sh"})
        )
        .await
        .is_err()
    );

    // Private managed data remains authoritative until explicit reconciliation;
    // a changed exported copy cannot silently replace it at read time.
    b.write(
        &format!("skills/{KEY}/SKILL.md"),
        &BODY.replace("review-alias", "disk-alias").into_bytes(),
    )?;
    b.write(
        &format!("skills/{KEY}/references/disk-only.md"),
        b"stale filesystem data",
    )?;
    let authoritative = b
        .call("skill_view", json!({"name":"updated-alias"}))
        .await?;
    assert_eq!(authoritative["source"], "managed_store");
    assert_eq!(
        authoritative["shadowed"][0]["selected_source"],
        "managed_store"
    );
    assert!(
        b.call("skill_view", json!({"name":"disk-alias"}))
            .await
            .is_err()
    );
    assert!(
        b.call(
            "skill_view",
            json!({"name":"updated-alias","file_path":"references/disk-only.md"})
        )
        .await
        .is_err()
    );
    b.write(
        &format!("skills/{KEY}/SKILL.md"),
        BODY.replace("review-alias", "updated-alias").as_bytes(),
    )?;
    fs::remove_file(
        b.root
            .path()
            .join(format!("profile/skills/{KEY}/references/disk-only.md")),
    )?;

    a.call(
        "skill_manage",
        json!({"operations":[{"action":"delete","name":KEY}]}),
    )
    .await?;
    a.sync(hub.path(), "a")?;
    b.sync(hub.path(), "b")?;
    assert_eq!(b.call("skills_list", json!({})).await?["count"], 0);
    for alias in ["updated-alias", "review", KEY] {
        assert!(b.call("skill_view", json!({"name":alias})).await.is_err());
    }
    // Returning a stale exported copy cannot resurrect a managed deletion.
    b.write(&format!("skills/{KEY}/SKILL.md"), BODY.as_bytes())?;
    assert_eq!(b.call("skills_list", json!({})).await?["count"], 0);
    assert!(
        b.call("skill_view", json!({"name":"review-alias"}))
            .await
            .is_err()
    );
    Ok(())
}
