use std::path::PathBuf;

pub(crate) struct Server {
    pub(crate) moddir: PathBuf,
    pub(crate) cli: PathBuf,
    pub(crate) secret: String,
}
