//! Crash-recoverable multi-file replacement. This is *not* a multi-rename
//! atomic operation. Readers requiring a consistent snapshot take a shared
//! descriptor lock. Lock-free readers may only inspect individual documents.

use crate::fs::{valid_id, MAX_DOCUMENT};
use crate::{sha256, EntryKind, Error, Result, Store};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

const JOURNALS: &str = ".state/transactions";
const MAX_CHANGES: usize = 64;
const MAX_TRANSACTION_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct Change {
    pub path: String,
    /// The caller's observed digest. None means the file must not exist.
    pub expected: Option<String>,
    /// None requests removal; an empty byte vector is an ordinary empty file.
    pub value: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    path: String,
    old: Option<String>,
    new: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    schema: u32,
    id: String,
    committed: bool,
    records: Vec<Record>,
}

pub struct Transaction;

#[derive(Clone, Debug, Default, Serialize)]
pub struct Recovery {
    pub rolled_back: usize,
    pub committed_cleaned: usize,
}

#[derive(Clone, Debug)]
pub struct Commit {
    pub cleanup_pending: bool,
}

fn digest(value: &Option<Vec<u8>>) -> Option<String> {
    value.as_ref().map(|bytes| sha256(bytes))
}

fn check_path(path: &str) -> Result<()> {
    if path.is_empty()
        || path.len() > 2048
        || path.starts_with('/')
        || path
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
        || path.bytes().any(|b| b < 0x20 || b == 0x7f)
        || path == ".state/lock"
        || path.starts_with(JOURNALS)
    {
        return Err(Error::new(
            "unsafe_transaction",
            "The transaction contains an invalid target path",
        ));
    }
    Ok(())
}

fn check_digest(value: &Option<String>) -> bool {
    value.as_ref().is_none_or(|value| {
        value.len() == 64
            && value
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

fn directory(id: &str) -> Result<String> {
    if !valid_id(id) {
        return Err(Error::new("invalid_id", "The transaction ID is invalid"));
    }
    Ok(format!("{JOURNALS}/{id}"))
}

fn journal_path(id: &str) -> Result<String> {
    Ok(format!("{}/journal.json", directory(id)?))
}

fn validate(journal: &Journal, id: &str) -> Result<()> {
    if journal.schema != 1 || journal.id != id || journal.records.len() > MAX_CHANGES {
        return Err(Error::new(
            "invalid_journal",
            "The recovery journal is not recognized",
        ));
    }
    let mut paths = BTreeSet::new();
    for record in &journal.records {
        check_path(&record.path)?;
        if !paths.insert(&record.path) || !check_digest(&record.old) || !check_digest(&record.new) {
            return Err(Error::new(
                "invalid_journal",
                "The recovery journal has duplicate or invalid records",
            ));
        }
    }
    Ok(())
}

fn blob<S: Store>(
    store: &S,
    id: &str,
    index: usize,
    kind: &str,
    expected: &Option<String>,
) -> Result<Option<Vec<u8>>> {
    let path = format!("{}/{index}.{kind}", directory(id)?);
    let value = store.read(&path, MAX_DOCUMENT)?;
    if digest(&value) != *expected {
        return Err(Error::new(
            "invalid_journal",
            "A recovery blob is missing or has changed",
        ));
    }
    Ok(value)
}

fn apply<S: Store>(store: &S, path: &str, value: &Option<Vec<u8>>) -> Result<()> {
    match value {
        Some(bytes) => store.write(path, bytes),
        None => store.remove(path),
    }
}

fn clean<S: Store>(store: &S, journal: &Journal) -> Result<()> {
    let dir = directory(&journal.id)?;
    // The journal is removed last. Partial cleanup of a committed transaction
    // is safe: recovery only cleans it, and never needs its old/new blobs.
    for index in 0..journal.records.len() {
        store.remove(&format!("{dir}/{index}.old"))?;
        store.remove(&format!("{dir}/{index}.new"))?;
    }
    for entry in store.list(&dir, MAX_CHANGES * 2 + 8)? {
        if entry.kind == EntryKind::File && entry.name.strip_prefix(".tmp-").is_some_and(valid_id) {
            store.remove(&format!("{dir}/{}", entry.name))?;
        }
    }
    store.remove(&journal_path(&journal.id)?)?;
    store.remove_dir(&dir)
}

fn rollback<S: Store>(store: &S, journal: &Journal) -> Result<()> {
    // Validate *all* evidence before changing any target. A corrupt late blob
    // must not trigger a partially speculative rollback of earlier files.
    let mut old_values = Vec::with_capacity(journal.records.len());
    for (index, record) in journal.records.iter().enumerate() {
        let old = blob(store, &journal.id, index, "old", &record.old)?;
        let _new = blob(store, &journal.id, index, "new", &record.new)?;
        let current = digest(&store.read(&record.path, MAX_DOCUMENT)?);
        if current != record.old && current != record.new {
            return Err(Error::new("recovery_conflict", "A transaction target changed outside this operation; recovery evidence was retained").changed());
        }
        old_values.push(old);
    }
    for (record, old) in journal.records.iter().zip(old_values.iter()).rev() {
        let current = digest(&store.read(&record.path, MAX_DOCUMENT)?);
        if current == record.old {
            continue;
        }
        if current != record.new {
            return Err(Error::new(
                "recovery_conflict",
                "A target changed while recovery held the runtime lock",
            )
            .changed());
        }
        apply(store, &record.path, old)?;
    }
    // Mark a rolled-back journal as committed *to its old values* before
    // deleting blobs. Otherwise a crash during cleanup could make a valid
    // rollback look like an incomplete journal on the next boot.
    let mut resolved = journal.clone();
    resolved.committed = true;
    store.write(&journal_path(&journal.id)?, &serde_json::to_vec(&resolved)?)?;
    clean(store, &resolved)
}

impl Transaction {
    /// The application must hold its exclusive, validated descriptor lock for
    /// this entire call and for recovery. Expected hashes additionally reject
    /// stale drafts and accidental writes by a caller using the wrong lock.
    pub fn commit<S: Store>(store: &S, id: &str, changes: &[Change]) -> Result<Commit> {
        let dir = directory(id)?;
        if changes.is_empty() || changes.len() > MAX_CHANGES {
            return Err(Error::new(
                "invalid_transaction",
                "A transaction must contain 1 to 64 changes",
            ));
        }
        if !store.list(&dir, MAX_CHANGES * 2 + 8)?.is_empty() {
            return Err(Error::new(
                "transaction_exists",
                "The transaction ID already has recovery evidence",
            ));
        }
        let mut records = Vec::new();
        let mut values = Vec::new();
        let mut paths = BTreeSet::new();
        let mut size = 0_usize;
        for change in changes {
            check_path(&change.path)?;
            if !paths.insert(&change.path) || !check_digest(&change.expected) {
                return Err(Error::new(
                    "invalid_transaction",
                    "Transaction targets must be unique and have valid expected digests",
                ));
            }
            let old = store.read(&change.path, MAX_DOCUMENT)?;
            if digest(&old) != change.expected {
                return Err(Error::new(
                    "revision_conflict",
                    "The configuration changed since this draft was read",
                )
                .retry());
            }
            if change
                .value
                .as_ref()
                .is_some_and(|v| v.len() > MAX_DOCUMENT)
            {
                return Err(Error::new(
                    "too_large",
                    "A transaction document exceeds its limit",
                ));
            }
            size = size
                .saturating_add(old.as_ref().map_or(0, Vec::len))
                .saturating_add(change.value.as_ref().map_or(0, Vec::len));
            if size > MAX_TRANSACTION_BYTES {
                return Err(Error::new(
                    "too_large",
                    "The complete transaction exceeds its limit",
                ));
            }
            records.push(Record {
                path: change.path.clone(),
                old: digest(&old),
                new: digest(&change.value),
            });
            values.push((old, change.value.clone()));
        }
        let mut journal = Journal {
            schema: 1,
            id: id.into(),
            committed: false,
            records,
        };
        // Staging failures cannot have changed a target. No prepared journal
        // exists until every rollback blob is durable.
        for (index, (old, new)) in values.iter().enumerate() {
            if let Some(value) = old {
                store.write(&format!("{dir}/{index}.old"), value)?;
            }
            if let Some(value) = new {
                store.write(&format!("{dir}/{index}.new"), value)?;
            }
        }
        store.write(&journal_path(id)?, &serde_json::to_vec(&journal)?)?;
        for (record, (_, new)) in journal.records.iter().zip(values.iter()) {
            let result = (|| {
                if digest(&store.read(&record.path, MAX_DOCUMENT)?) != record.old {
                    return Err(Error::new(
                        "revision_conflict",
                        "A transaction target changed before activation",
                    )
                    .changed());
                }
                apply(store, &record.path, new)
            })();
            if let Err(error) = result {
                return match rollback(store, &journal) {
                    Ok(()) => Err(error),
                    Err(_) => Err(Error::new(
                        "rollback_incomplete",
                        "The operation failed and recovery must finish before another mutation",
                    )
                    .changed()),
                };
            }
        }
        journal.committed = true;
        // A failure here leaves either a prepared or a committed journal. Do
        // not guess which rename was durable, and do not claim success.
        if let Err(error) = store.write(&journal_path(id)?, &serde_json::to_vec(&journal)?) {
            return Err(error.changed());
        }
        Ok(Commit {
            cleanup_pending: clean(store, &journal).is_err(),
        })
    }

    pub fn recover<S: Store>(store: &S) -> Result<Recovery> {
        let mut report = Recovery::default();
        for entry in store.list(JOURNALS, 64)? {
            if entry.kind != EntryKind::Directory || !valid_id(&entry.name) {
                return Err(Error::new(
                    "invalid_journal",
                    "Unexpected recovery directory entry; refusing to delete it",
                ));
            }
            let path = journal_path(&entry.name)?;
            let Some(bytes) = store.read(&path, MAX_DOCUMENT)? else {
                // Interrupted *preparation* cannot have modified a target.
                // Only bounded, numbered staging files from this private
                // transaction directory may be discarded.
                let dir = directory(&entry.name)?;
                for staged in store.list(&dir, MAX_CHANGES * 2 + 8)? {
                    let valid = staged.name.rsplit_once('.').is_some_and(|(number, kind)| {
                        matches!(kind, "old" | "new")
                            && number.parse::<usize>().is_ok_and(|n| n < MAX_CHANGES)
                    }) || staged.name.strip_prefix(".tmp-").is_some_and(valid_id);
                    if staged.kind != EntryKind::File || !valid {
                        return Err(Error::new(
                            "invalid_journal",
                            "An unprepared transaction has unknown contents",
                        ));
                    }
                    store.remove(&format!("{dir}/{}", staged.name))?;
                }
                store.remove_dir(&dir)?;
                continue;
            };
            let journal: Journal = serde_json::from_slice(&bytes)?;
            validate(&journal, &entry.name)?;
            if journal.committed {
                clean(store, &journal)?;
                report.committed_cleaned += 1;
            } else {
                rollback(store, &journal)?;
                report.rolled_back += 1;
            }
        }
        Ok(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{random_id, Root};
    use std::cell::Cell;
    use std::panic::{catch_unwind, AssertUnwindSafe};

    struct Crash<'a> {
        root: &'a Root,
        at: usize,
        count: Cell<usize>,
        after: bool,
    }
    impl Crash<'_> {
        fn tick(&self) {
            let n = self.count.get();
            self.count.set(n + 1);
            if n == self.at {
                panic!("injected power loss");
            }
        }
    }
    impl Store for Crash<'_> {
        fn read(&self, p: &str, l: usize) -> Result<Option<Vec<u8>>> {
            self.root.read(p, l)
        }
        fn write(&self, p: &str, v: &[u8]) -> Result<()> {
            if !self.after {
                self.tick();
            }
            self.root.write(p, v)?;
            if self.after {
                self.tick();
            }
            Ok(())
        }
        fn remove(&self, p: &str) -> Result<()> {
            if !self.after {
                self.tick();
            }
            self.root.remove(p)?;
            if self.after {
                self.tick();
            }
            Ok(())
        }
        fn list(&self, p: &str, l: usize) -> Result<Vec<crate::Entry>> {
            self.root.list(p, l)
        }
        fn remove_dir(&self, p: &str) -> Result<()> {
            if !self.after {
                self.tick();
            }
            self.root.remove_dir(p)?;
            if self.after {
                self.tick();
            }
            Ok(())
        }
    }

    #[test]
    fn power_loss_at_every_mutation_recovers_whole_old_or_whole_new_state() {
        for after in [false, true] {
            for at in 0..24 {
                let path = std::env::temp_dir().join(format!("kamfw-tx-{}", random_id().unwrap()));
                std::fs::create_dir(&path).unwrap();
                let root = Root::open(&path).unwrap();
                root.write(".config/a", b"old-a").unwrap();
                root.write(".config/b", b"old-b").unwrap();
                let changes = [
                    Change {
                        path: ".config/a".into(),
                        expected: Some(sha256(b"old-a")),
                        value: Some(b"new-a".to_vec()),
                    },
                    Change {
                        path: ".config/b".into(),
                        expected: Some(sha256(b"old-b")),
                        value: None,
                    },
                    Change {
                        path: ".config/c".into(),
                        expected: None,
                        value: Some(b"new-c".to_vec()),
                    },
                ];
                let id = random_id().unwrap();
                let crash = Crash {
                    root: &root,
                    at,
                    count: Cell::new(0),
                    after,
                };
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    Transaction::commit(&crash, &id, &changes)
                }));
                Transaction::recover(&root).unwrap();
                let a = root.read(".config/a", 64).unwrap();
                let b = root.read(".config/b", 64).unwrap();
                let c = root.read(".config/c", 64).unwrap();
                assert!(
                    (a == Some(b"old-a".to_vec()) && b == Some(b"old-b".to_vec()) && c.is_none())
                        || (a == Some(b"new-a".to_vec())
                            && b.is_none()
                            && c == Some(b"new-c".to_vec())),
                    "mixed state at {at}, after={after}"
                );
                Transaction::recover(&root).unwrap();
                assert!(root.list(JOURNALS, 64).unwrap().is_empty());
                std::fs::remove_dir_all(path).unwrap();
            }
        }
    }

    #[test]
    fn stale_revision_and_duplicate_paths_do_not_modify_targets() {
        let path = std::env::temp_dir().join(format!("kamfw-tx-{}", random_id().unwrap()));
        std::fs::create_dir(&path).unwrap();
        let root = Root::open(&path).unwrap();
        root.write(".config/a", b"actual").unwrap();
        let change = Change {
            path: ".config/a".into(),
            expected: None,
            value: Some(b"wrong".to_vec()),
        };
        assert_eq!(
            Transaction::commit(&root, &random_id().unwrap(), &[change])
                .err()
                .unwrap()
                .code,
            "revision_conflict"
        );
        assert_eq!(root.read(".config/a", 32).unwrap().unwrap(), b"actual");
        std::fs::remove_dir_all(path).unwrap();
    }
}
