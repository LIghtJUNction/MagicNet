//! Small, Linux/Android module runtime. No shell dispatch, network policy, or
//! caller-selected environment paths are part of this crate.
//!
//! A `Root` pins an already-open directory. All private files are opened
//! relative to directory descriptors without following symlinks. Mutations are
//! serialized with descriptor locks; multi-file changes use a recovery journal.

pub mod error;
pub mod fs;
mod fs_socket;
pub mod lock;
pub mod process;
pub mod run;
pub mod transaction;
pub mod worker;

pub use error::{Error, Result};
pub use fs::{random_id, sha256, Entry, EntryKind, Root, Store};
pub use lock::{Guard, LockMode};
pub use transaction::{Change, Transaction};
