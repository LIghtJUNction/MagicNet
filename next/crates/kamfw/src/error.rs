use serde::Serialize;
use std::fmt;

pub type Result<T> = std::result::Result<T, Error>;

/// Messages are written by the application, never populated with command
/// output, subscription URLs, or raw user configuration.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Error {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    /// A failed operation can already have changed a file. Its journal must be
    /// reconciled; an error is not proof that no side effects occurred.
    pub effects_possible: bool,
}

impl Error {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            retryable: false,
            effects_possible: false,
        }
    }

    pub fn retry(mut self) -> Self {
        self.retryable = true;
        self
    }

    pub fn changed(mut self) -> Self {
        self.effects_possible = true;
        self
    }

    pub fn io(context: &str, error: std::io::Error) -> Self {
        let code = match error.kind() {
            std::io::ErrorKind::NotFound => "not_found",
            std::io::ErrorKind::PermissionDenied => "permission_denied",
            std::io::ErrorKind::AlreadyExists => "already_exists",
            std::io::ErrorKind::WouldBlock => "busy",
            std::io::ErrorKind::TimedOut => "timeout",
            _ => "io_error",
        };
        // ErrorKind is bounded and cannot contain a remote URL or a filename
        // obtained from untrusted input.
        Self::new(code, &format!("{context}: {:?}", error.kind()))
    }

    pub fn os(context: &str) -> Self {
        Self::io(context, std::io::Error::last_os_error())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for Error {}

impl From<serde_json::Error> for Error {
    fn from(_: serde_json::Error) -> Self {
        Self::new(
            "invalid_json",
            "The JSON document does not match the required format",
        )
    }
}
