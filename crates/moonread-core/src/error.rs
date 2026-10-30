#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, thiserror::Error, uniffi::Error)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReaderError {
    #[error("{message}")]
    Backup { message: String },
    #[error("文件访问失败：{message}")]
    Io { message: String },
    #[error("数据存储失败：{message}")]
    Storage { message: String },
    #[error("正文编码无效或不支持：{message}")]
    Decode { message: String },
    #[error("单个组合字符超过 64 KiB，无法安全分块")]
    GraphemeTooLong,
    #[error("文件具有二进制特征，或文字编码选择不正确")]
    BinaryContent,
    #[error("正文超过可存储的范围")]
    TextCapacityExceeded,
    #[error("未找到书籍或正文片段")]
    NotFound,
    #[error("文件没有正文")]
    EmptyBook,
    #[error("设置值无效")]
    InvalidSettings,
    #[error("准备已暂停，已读内容和位置已保留")]
    Paused,
    #[error("小说仍在准备，请稍后重试")]
    ImportBusy,
    #[error("源文件已改变，请重新打开；之前的阅读位置仍保留")]
    SourceChanged,
    #[error("Database predates the supported v20 baseline; no migration is available")]
    IncompatibleStore,
    #[error("Database version {version} is newer than supported version {current}; update the app")]
    StoreTooNew { version: u32, current: u32 },
    #[error("Local reading data belongs to a different iCloud account")]
    CloudAccountChanged,
    #[error("Invalid text range")]
    InvalidRange,
    #[error("Search pattern: {message}")]
    SearchPattern { message: String },
    #[error("A paragraph exceeds the search memory limit")]
    SearchLineTooLong,
}

impl From<std::io::Error> for ReaderError {
    fn from(value: std::io::Error) -> Self {
        Self::Io {
            message: value.to_string(),
        }
    }
}
impl From<rusqlite::Error> for ReaderError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Storage {
            message: value.to_string(),
        }
    }
}
pub(crate) type Result<T> = std::result::Result<T, ReaderError>;
