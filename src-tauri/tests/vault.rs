use std::fs;
use tearoff_lib::testing::*;

fn vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let v = Vault::open(dir.path().to_path_buf()).unwrap();
    (dir, v)
}

#[test]
fn write_read_round_trip_and_listing() {
    let (dir, mut v) = vault();
    let meta = v.write_note("Daily/2026-11-15.md", "- [ ] 待办\n\n**想法**\n", None).unwrap();
    assert_eq!(meta.title, "2026-11-15");
    assert_eq!(meta.folder, "Daily");
    assert_eq!(meta.daily_date.as_deref(), Some("2026-11-15"));
    assert_eq!(meta.preview, "待办 想法");
    assert_eq!(fs::read_to_string(dir.path().join("Daily/2026-11-15.md")).unwrap(), "- [ ] 待办\n\n**想法**\n");
    assert_eq!(v.read_note("Daily/2026-11-15.md").unwrap().modified, meta.modified);

    v.write_note("随笔.md", "x", None).unwrap();
    fs::create_dir_all(dir.path().join("assets")).unwrap();
    fs::write(dir.path().join("assets/not-a-note.md"), "x").unwrap();
    fs::create_dir_all(dir.path().join(".trash")).unwrap();
    fs::write(dir.path().join(".trash/old.md"), "x").unwrap();
    let mut paths: Vec<_> = v.list_notes().into_iter().map(|n| n.path).collect();
    paths.sort();
    assert_eq!(paths, ["Daily/2026-11-15.md", "随笔.md"]);
}

#[test]
fn missing_note_reads_as_empty_and_is_not_created() {
    let (dir, v) = vault();
    let doc = v.read_note("Daily/2026-01-01.md").unwrap();
    assert_eq!((doc.content.as_str(), doc.modified), ("", 0));
    assert!(!dir.path().join("Daily").exists());
}

#[test]
fn write_refuses_when_file_changed_underneath() {
    let (dir, mut v) = vault();
    let meta = v.write_note("a.md", "one", None).unwrap();
    // Same base → fine.
    let meta2 = v.write_note("a.md", "two", Some(meta.modified)).unwrap();
    // External edit with a different mtime.
    let file = fs::OpenOptions::new().write(true).open(dir.path().join("a.md")).unwrap();
    file.set_modified(std::time::SystemTime::now() + std::time::Duration::from_secs(5)).unwrap();
    let err = v.write_note("a.md", "three", Some(meta2.modified)).unwrap_err();
    assert_eq!(err.to_string(), "conflict");
    assert_eq!(fs::read_to_string(dir.path().join("a.md")).unwrap(), "two");
    // Explicit overwrite is still possible.
    v.write_note("a.md", "three", None).unwrap();
}

#[test]
fn paths_cannot_escape_the_vault() {
    let (_dir, mut v) = vault();
    for bad in ["../x.md", "/etc/x.md", "a/../../x.md", "x.txt", ""] {
        assert!(v.write_note(bad, "x", None).is_err(), "{bad}");
        assert!(v.read_note(bad).is_err(), "{bad}");
    }
}

#[test]
fn create_picks_free_names_and_rename_keeps_pin() {
    let (dir, mut v) = vault();
    assert_eq!(v.create_note(None).unwrap().path, "未命名.md");
    assert_eq!(v.create_note(None).unwrap().path, "未命名 2.md");
    assert_eq!(v.create_note(Some("a/b:c")).unwrap().path, "abc.md");

    v.set_pinned("未命名.md", true).unwrap();
    v.reorder_cards(&["note:未命名.md".to_string()]).unwrap();
    assert_eq!(v.rename_note("未命名.md", "未命名 2").unwrap_err().to_string(), "exists:未命名 2");
    let renamed = v.rename_note("未命名.md", "实验记录").unwrap();
    assert_eq!(renamed.path, "实验记录.md");
    assert!(renamed.pinned);
    assert_eq!(renamed.order, Some(0));
    assert!(!dir.path().join("未命名.md").exists());

    // The sidecar survives a reopen.
    let reopened = Vault::open(dir.path().to_path_buf()).unwrap();
    assert!(reopened.list_notes().iter().any(|n| n.path == "实验记录.md" && n.pinned));
}

#[test]
fn search_matches_title_and_body_case_insensitively() {
    let (_dir, mut v) = vault();
    v.write_note("缓存.md", "按请求指纹分桶，命中率 UP。", None).unwrap();
    v.write_note("别的.md", "无关", None).unwrap();
    let hits = v.search("up");
    assert_eq!(hits.len(), 1);
    assert!(hits[0].snippet.contains("命中率"));
    assert_eq!(v.search("缓存").len(), 1);
    assert!(v.search("  ").is_empty());
}

#[test]
fn images_are_stored_beside_the_note() {
    let (dir, mut v) = vault();
    v.write_note("论文/想法.md", "x", None).unwrap();
    let src = v.save_image("论文/想法.md", "pasted.png", b"png").unwrap();
    assert!(src.starts_with("assets/image-") && src.ends_with(".png"));
    assert_eq!(fs::read(dir.path().join("论文").join(&src)).unwrap(), b"png");
}

#[test]
fn legacy_meta_is_imported_once_and_left_untouched() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("常用命令.md"), "ssh").unwrap();
    fs::create_dir_all(dir.path().join(".tearoff")).unwrap();
    let legacy = r#"{
      "version": 4,
      "notes": {
        "A1": {"path": "常用命令.md", "createdAt": "2026-09-01T08:00:00Z", "modifiedAt": "2026-09-01T08:00:00Z", "savedAt": "2026-09-01T08:00:00Z", "tags": [], "pinned": true, "sortOrder": 3}
      },
      "finderCards": {
        "C1": {"title": null, "folder": "", "favorites": [{"id": "F1", "path": "/tmp/常用", "displayName": "常用"}], "selectedFavoriteID": "F1", "currentPath": null, "viewMode": "list", "sortKey": "modifiedDate", "sortAscending": false, "listHeight": 300, "createdAt": "2026-09-01T08:00:00Z", "modifiedAt": "2026-09-01T08:00:00Z"}
      }
    }"#;
    let meta_path = dir.path().join(".tearoff/meta.json");
    fs::write(&meta_path, legacy).unwrap();

    let v = Vault::open(dir.path().to_path_buf()).unwrap();
    let note = &v.list_notes()[0];
    assert!(note.pinned);
    assert_eq!(note.order, Some(3));
    assert_eq!(note.created, 1788249600000);
    let card = &v.folder_cards()[0];
    assert_eq!((card.id.as_str(), card.view_mode.as_str(), card.sort_key.as_str(), card.sort_asc, card.list_height), ("C1", "list", "modified", false, 300.0));
    assert_eq!(card.favorites[0].name, "常用");

    assert_eq!(fs::read_to_string(&meta_path).unwrap(), legacy, "legacy sidecar must never be rewritten");
    assert!(dir.path().join(".tearoff/v5.json").exists());
}

#[test]
fn preview_strips_syntax() {
    assert_eq!(preview_of("---\ntitle: x\n---\n\n# 标题\n\n- [x] 做完\n1. 第一\n> 引用 `code`\n\n```rust\nfn main() {}\n```\n| a | b |\n|---|---|\n"), "标题 做完 第一 引用 code | a | b |");
}

#[test]
fn finder_moves_refuse_clashes_and_self_nesting() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    fs::create_dir_all(root.join("archives/sub")).unwrap();
    fs::write(root.join("archives/alpha.txt"), "a").unwrap();
    fs::write(root.join("archives/beta.txt"), "b").unwrap();
    fs::write(root.join("beta.txt"), "other").unwrap();

    // The bug-report scenario: drag a file from a folder up to its parent.
    move_into(&[root.join("archives/alpha.txt")], root, false).unwrap();
    assert!(root.join("alpha.txt").exists() && !root.join("archives/alpha.txt").exists());

    // A clash moves nothing and overwrites nothing.
    let err = move_into(&[root.join("archives/beta.txt")], root, false).unwrap_err();
    assert_eq!(err.to_string(), "exists:beta.txt");
    assert_eq!(fs::read_to_string(root.join("beta.txt")).unwrap(), "other");
    assert!(root.join("archives/beta.txt").exists());

    // Dropping onto the folder it already lives in is a no-op.
    move_into(&[root.join("alpha.txt")], root, false).unwrap();
    // A folder cannot go inside itself.
    assert!(move_into(&[root.join("archives")], &root.join("archives/sub"), false).is_err());
    // Copy leaves the source.
    move_into(&[root.join("alpha.txt")], &root.join("archives"), true).unwrap();
    assert!(root.join("alpha.txt").exists() && root.join("archives/alpha.txt").exists());

    let names: Vec<_> = list_dir(&root.join("archives"), false).unwrap().into_iter().map(|e| e.name).collect();
    assert_eq!(names.len(), 3);
    assert_eq!(list_dir(&root.join("nope"), false).unwrap_err().to_string(), "notFound");

    rename(&root.join("alpha.txt"), "gamma.txt").unwrap();
    assert_eq!(rename(&root.join("gamma.txt"), "beta.txt").unwrap_err().to_string(), "exists:beta.txt");
    assert!(rename(&root.join("gamma.txt"), "a/b").is_err());
    assert_eq!(new_folder(root).unwrap().file_name().unwrap(), "新建文件夹");
    assert_eq!(new_folder(root).unwrap().file_name().unwrap(), "新建文件夹 2");
}
