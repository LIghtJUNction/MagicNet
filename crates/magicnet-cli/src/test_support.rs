use std::fs;
use std::ops::Deref;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::App;

static NEXT_TEMP_APP: AtomicU64 = AtomicU64::new(0);

pub(crate) struct TempApp {
    app: App,
    root: PathBuf,
}

impl Deref for TempApp {
    type Target = App;

    fn deref(&self) -> &Self::Target {
        &self.app
    }
}

impl Drop for TempApp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

pub(crate) fn temp_app() -> TempApp {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is after the Unix epoch")
        .as_nanos();
    let sequence = NEXT_TEMP_APP.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!(
        "magicnet-cli-test-{}-{stamp}-{sequence}",
        std::process::id()
    ));
    fs::create_dir_all(&root).expect("create temporary module directory");
    TempApp {
        app: App::for_test(root.clone()),
        root,
    }
}
