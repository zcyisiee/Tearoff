//! File operations behind folder cards. Every path here is absolute and
//! chosen by the user; nothing is ever overwritten or permanently deleted.

use crate::error::{Error, Result};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: i64,
    pub ext: String,
}

pub fn list_dir(dir: &Path, show_hidden: bool) -> Result<Vec<DirEntry>> {
    let read = fs::read_dir(dir).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => Error::NotFound,
        _ => Error::Io(e),
    })?;
    let mut out = Vec::new();
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !show_hidden && name.starts_with('.') {
            continue;
        }
        // Follow symlinks so a linked folder browses like a folder.
        let Ok(meta) = fs::metadata(entry.path()) else { continue };
        let is_dir = meta.is_dir();
        out.push(DirEntry {
            ext: if is_dir { String::new() } else { Path::new(&name).extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default() },
            path: entry.path().to_string_lossy().into_owned(),
            is_dir,
            size: if is_dir { 0 } else { meta.len() },
            modified: meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0),
            name,
        });
    }
    Ok(out)
}

fn copy_recursive(from: &Path, to: &Path) -> Result<()> {
    if fs::metadata(from)?.is_dir() {
        fs::create_dir(to)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            copy_recursive(&entry.path(), &to.join(entry.file_name()))?;
        }
    } else {
        fs::copy(from, to)?;
    }
    Ok(())
}

/// Move (or copy) `sources` into `dest_dir`. Checked up front for name
/// clashes and for moving a folder into itself, so the batch is all-or-nothing
/// with respect to those refusals.
pub fn move_into(sources: &[PathBuf], dest_dir: &Path, copy: bool) -> Result<()> {
    if !dest_dir.is_dir() {
        return Err(Error::NotFound);
    }
    let dest_canon = fs::canonicalize(dest_dir)?;
    let mut plan = Vec::new();
    for src in sources {
        let name = src.file_name().ok_or(Error::InvalidPath)?;
        let src_canon = fs::canonicalize(src).map_err(|_| Error::NotFound)?;
        if src_canon.parent() == Some(dest_canon.as_path()) {
            continue; // already there
        }
        if dest_canon.starts_with(&src_canon) {
            return Err(Error::Other("不能把文件夹移到它自己里面".into()));
        }
        let target = dest_dir.join(name);
        if target.exists() {
            return Err(Error::Exists(name.to_string_lossy().into_owned()));
        }
        plan.push((src.clone(), target));
    }
    for (src, target) in plan {
        if copy {
            copy_recursive(&src, &target)?;
        } else if fs::rename(&src, &target).is_err() {
            // Different volume: copy, then send the original to the trash.
            copy_recursive(&src, &target)?;
            trash::delete(&src).map_err(|e| Error::Other(e.to_string()))?;
        }
    }
    Ok(())
}

pub fn rename(path: &Path, new_name: &str) -> Result<()> {
    if new_name.is_empty() || new_name.contains(['/', '\\']) || new_name == "." || new_name == ".." {
        return Err(Error::InvalidPath);
    }
    let target = path.with_file_name(new_name);
    let same_file = target.to_string_lossy().to_lowercase() == path.to_string_lossy().to_lowercase();
    if target.exists() && !same_file {
        return Err(Error::Exists(new_name.to_string()));
    }
    fs::rename(path, target)?;
    Ok(())
}

pub fn trash(paths: &[PathBuf]) -> Result<()> {
    trash::delete_all(paths).map_err(|e| Error::Other(e.to_string()))
}

pub fn new_folder(dir: &Path) -> Result<PathBuf> {
    let base = "新建文件夹";
    let mut target = dir.join(base);
    let mut i = 2;
    while target.exists() {
        target = dir.join(format!("{base} {i}"));
        i += 1;
    }
    fs::create_dir(&target)?;
    Ok(target)
}
