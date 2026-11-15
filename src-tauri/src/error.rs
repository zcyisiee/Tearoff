use serde::Serialize;

/// Errors cross the IPC boundary as plain strings. A few are stable tokens the
/// frontend matches on: `conflict`, `exists:<name>`, `notFound`.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("conflict")]
    Conflict,
    #[error("exists:{0}")]
    Exists(String),
    #[error("notFound")]
    NotFound,
    #[error("invalid path")]
    InvalidPath,
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Other(String),
}

impl Serialize for Error {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Other(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
