use std::path::PathBuf;

pub(crate) struct Server {
    pub(crate) moddir: PathBuf,
    pub(crate) cli: PathBuf,
    pub(crate) secret: String,
}

impl Server {
    pub(crate) fn clone_ref(&self) -> Self {
        Self {
            moddir: self.moddir.clone(),
            cli: self.cli.clone(),
            secret: self.secret.clone(),
        }
    }
}
