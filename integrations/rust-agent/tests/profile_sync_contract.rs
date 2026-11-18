//! Regression coverage for the pinned Orialis portable-profile contract.
#![cfg(unix)]

use hermes_rust_core::profile_sync::{
    SyncConfig, digest, exchange, read_one_with_skill_roots, run_sync, run_sync_with_transport,
};
use std::{fs, path::Path};
use tempfile::TempDir;

fn config(root: &Path, node: &str) -> SyncConfig {
    let profile = root.join(node);
    fs::create_dir_all(&profile).unwrap();
    SyncConfig {
        profile,
        state_dir: root.join(format!("{node}-state")),
        node: node.into(),
        hub_store: Some(root.join("hub")),
        ssh: vec![],
        force_payload: false,
        allowed_skill_roots: vec![],
    }
}

fn put(profile: &Path, relative: &str, data: &[u8]) {
    let path = profile.join(relative);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, data).unwrap();
}

#[cfg(unix)]
#[test]
fn new_binary_support_file_materializes_approved_link_and_survives_delete_readd() {
    use std::os::unix::fs::symlink;
    for link_is_skills_root in [false, true] {
        let root = TempDir::new().unwrap();
        let mut a = config(root.path(), "a");
        let b = config(root.path(), "b");
        let library = root.path().join("library");
        let prefix = if link_is_skills_root {
            "skills"
        } else {
            "skills/shared"
        };
        put(&library, "SKILL.md", b"shared skill\n");
        put(&library, "references/existing.txt", b"existing reference\n");
        if !link_is_skills_root {
            fs::create_dir(a.profile.join("skills")).unwrap();
        }
        symlink(&library, a.profile.join(prefix)).unwrap();
        a.allowed_skill_roots.push(library.clone());
        run_sync(&a).unwrap();
        run_sync(&b).unwrap();

        let relative = format!("{prefix}/assets/nested/template.bin");
        let bytes = b"\0\xffsupport\r\n\x80";
        put(&b.profile, &relative, bytes);
        run_sync(&b).unwrap();
        let lost = run_sync_with_transport(&a, |request| {
            exchange(a.hub_store.as_ref().unwrap(), request)?;
            anyhow::bail!("simulated lost response before local materialization")
        });
        assert!(lost.is_err());
        assert!(a.profile.join(prefix).is_symlink());
        assert!(!library.join("assets").exists());
        let outcome = run_sync(&a).unwrap();
        assert_eq!(outcome.applied, 1);
        assert!(outcome.conflicts.is_empty());
        assert!(!a.profile.join(prefix).is_symlink());
        assert_eq!(fs::read(a.profile.join(&relative)).unwrap(), bytes);
        assert_eq!(
            fs::read(a.profile.join(format!("{prefix}/SKILL.md"))).unwrap(),
            b"shared skill\n"
        );
        assert_eq!(
            fs::read(a.profile.join(format!("{prefix}/references/existing.txt"))).unwrap(),
            b"existing reference\n"
        );
        assert!(!library.join("assets").exists());
        assert_eq!(
            fs::read(library.join("SKILL.md")).unwrap(),
            b"shared skill\n"
        );

        fs::remove_file(b.profile.join(&relative)).unwrap();
        run_sync(&b).unwrap();
        run_sync(&a).unwrap();
        assert!(!a.profile.join(&relative).exists());
        put(&b.profile, &relative, bytes);
        run_sync(&b).unwrap();
        run_sync(&a).unwrap();
        assert_eq!(fs::read(a.profile.join(&relative)).unwrap(), bytes);
        assert_eq!(run_sync(&a).unwrap().applied, 0);
        assert!(!a.state_dir.join("materialization-incomplete.json").exists());
    }
}

#[test]
fn explicit_resnapshot_repairs_missing_binary_object_without_changing_lineage() {
    let root = TempDir::new().unwrap();
    let mut a = config(root.path(), "a");
    let b = config(root.path(), "b");
    let bytes = b"\0\xffbinary support\r\n";
    put(&a.profile, "skills/demo/assets/template.bin", bytes);
    let first = run_sync(&a).unwrap();
    let prior_state = fs::read(a.state_dir.join("client.json")).unwrap();
    let object = a
        .hub_store
        .as_ref()
        .unwrap()
        .join("objects")
        .join(digest(bytes));
    fs::remove_file(&object).unwrap();
    assert!(run_sync(&a).is_err());
    assert_eq!(
        fs::read(a.state_dir.join("client.json")).unwrap(),
        prior_state
    );
    a.force_payload = true;
    let repaired = run_sync(&a).unwrap();
    assert_eq!(repaired.revision, first.revision);
    assert_eq!(repaired.applied, 0);
    assert_eq!(fs::read(object).unwrap(), bytes);
    run_sync(&b).unwrap();
    assert_eq!(
        fs::read(b.profile.join("skills/demo/assets/template.bin")).unwrap(),
        bytes
    );
}

#[cfg(unix)]
#[test]
fn new_support_file_materializes_internal_skill_alias_without_changing_target() {
    use std::os::unix::fs::symlink;
    let root = TempDir::new().unwrap();
    let a = config(root.path(), "a");
    let b = config(root.path(), "b");
    put(&a.profile, "skills/original/SKILL.md", b"shared skill\n");
    symlink("original", a.profile.join("skills/alias")).unwrap();
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    put(
        &b.profile,
        "skills/alias/scripts/helper.py",
        b"#!/usr/bin/env python3\nprint('helper')\n",
    );
    run_sync(&b).unwrap();
    assert_eq!(run_sync(&a).unwrap().applied, 1);
    assert!(!a.profile.join("skills/alias").is_symlink());
    assert!(a.profile.join("skills/alias/scripts/helper.py").is_file());
    assert!(!a.profile.join("skills/original/scripts").exists());
}

#[cfg(unix)]
#[test]
fn missing_linked_file_does_not_bypass_root_or_dangling_link_checks() {
    use std::os::unix::fs::symlink;
    let root = TempDir::new().unwrap();
    let a = config(root.path(), "a");
    let library = root.path().join("library");
    let outside = root.path().join("outside");
    fs::create_dir(&library).unwrap();
    fs::create_dir(&outside).unwrap();
    fs::create_dir(a.profile.join("skills")).unwrap();
    symlink(&library, a.profile.join("skills/shared")).unwrap();
    let allowed = [library.clone()];
    assert!(
        read_one_with_skill_roots(&a.profile, "skills/shared/new/asset.bin", &allowed)
            .unwrap()
            .is_none()
    );
    assert!(read_one_with_skill_roots(&a.profile, "skills/shared/new/asset.bin", &[]).is_err());
    symlink(&outside, library.join("escape")).unwrap();
    assert!(
        read_one_with_skill_roots(&a.profile, "skills/shared/escape/new/asset.bin", &allowed)
            .is_err()
    );
    symlink(library.join("absent"), library.join("dangling")).unwrap();
    assert!(
        read_one_with_skill_roots(&a.profile, "skills/shared/dangling/asset.bin", &allowed)
            .is_err()
    );
    assert!(!outside.join("new").exists());
}

#[cfg(unix)]
#[test]
fn concurrent_creation_under_approved_link_is_retained_as_a_conflict() {
    use std::os::unix::fs::symlink;
    let root = TempDir::new().unwrap();
    let mut a = config(root.path(), "a");
    let b = config(root.path(), "b");
    let library = root.path().join("library");
    put(&library, "SKILL.md", b"shared skill\n");
    fs::create_dir(a.profile.join("skills")).unwrap();
    symlink(&library, a.profile.join("skills/shared")).unwrap();
    a.allowed_skill_roots.push(library.clone());
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    let relative = "skills/shared/assets/template.bin";
    put(&b.profile, relative, b"remote\0");
    run_sync(&b).unwrap();
    let outcome = run_sync_with_transport(&a, |request| {
        let response = exchange(a.hub_store.as_ref().unwrap(), request)?;
        put(&library, "assets/template.bin", b"concurrent\0");
        Ok(response)
    })
    .unwrap();
    assert_eq!(outcome.conflicts, vec![relative]);
    assert_eq!(outcome.applied, 0);
    assert!(a.profile.join("skills/shared").is_symlink());
    assert_eq!(
        fs::read(library.join("assets/template.bin")).unwrap(),
        b"concurrent\0"
    );
}
