//! Syntax only. Authorization, symlinks and coordinated IO remain platform-owned.
use crate::{ReaderError, Result};
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum LibraryNameProfile {
    ManualForm,
    AiPreview,
    AiRename,
    FinalOperation,
}
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum LibraryInputError {
    #[error("empty")]
    Empty,
    #[error("absolute")]
    Absolute,
    #[error("empty component")]
    EmptyComponent,
    #[error("dot component")]
    DotComponent,
    #[error("nul")]
    Nul,
    #[error("separator")]
    Separator,
    #[error("backslash")]
    Backslash,
    #[error("colon")]
    Colon,
    #[error("hidden name")]
    HiddenName,
}
#[uniffi::export]
pub fn validate_relative_path(
    path: String,
    allow_root: bool,
) -> std::result::Result<(), LibraryInputError> {
    if path.is_empty() {
        return if allow_root {
            Ok(())
        } else {
            Err(LibraryInputError::Empty)
        };
    }
    if path.starts_with('/') {
        return Err(LibraryInputError::Absolute);
    }
    if path.contains('\0') {
        return Err(LibraryInputError::Nul);
    }
    for part in path.split('/') {
        if part.is_empty() {
            return Err(LibraryInputError::EmptyComponent);
        }
        if part == "." || part == ".." {
            return Err(LibraryInputError::DotComponent);
        }
    }
    Ok(())
}
#[uniffi::export]
pub fn validate_library_name(
    input: String,
    profile: LibraryNameProfile,
) -> std::result::Result<(), LibraryInputError> {
    use LibraryNameProfile::*;
    // These profiles preserve the pre-existing rejection stage of each entry point.
    if matches!(profile, AiRename) && input.contains('\\') {
        return Err(LibraryInputError::Backslash);
    }
    let empty = match profile {
        AiPreview => input.is_empty(),
        ManualForm => input
            .trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
            .is_empty(),
        AiRename | FinalOperation => input.trim().is_empty(),
    };
    if empty {
        return Err(LibraryInputError::Empty);
    }
    if input.contains('/') || (matches!(profile, AiPreview | AiRename) && input.contains('\\')) {
        return Err(LibraryInputError::Separator);
    }
    if !matches!(profile, AiPreview) && input.contains(':') {
        return Err(LibraryInputError::Colon);
    }
    if input.starts_with('.') {
        return Err(LibraryInputError::HiddenName);
    }
    if matches!(profile, AiRename | FinalOperation) {
        validate_relative_path(input, false)?;
    }
    Ok(())
}
pub(crate) fn relative(path: &str, allow_root: bool) -> Result<()> {
    validate_relative_path(path.into(), allow_root).map_err(|_| ReaderError::InvalidSettings)
}
#[uniffi::export]
pub fn library_child_path(parent: String, name: String) -> Result<String> {
    relative(&parent, true)?;
    validate_library_name(name.clone(), LibraryNameProfile::FinalOperation)
        .map_err(|_| ReaderError::InvalidSettings)?;
    Ok(if parent.is_empty() {
        name
    } else {
        format!("{parent}/{name}")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn entry_profiles_preserve_the_shared_input_contract() {
        let contract: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/library-input-contract-v1.json"
        ))
        .unwrap();
        for case in contract["names"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            for (column, profile) in [
                ("libraryName", LibraryNameProfile::FinalOperation),
                ("manualForm", LibraryNameProfile::ManualForm),
                ("aiPreview", LibraryNameProfile::AiPreview),
                ("aiRename", LibraryNameProfile::AiRename),
            ] {
                assert_eq!(
                    validate_library_name(name.into(), profile).is_ok(),
                    case[column].as_bool().unwrap(),
                    "{column}: {name:?}"
                );
            }
        }
        for case in contract["paths"].as_array().unwrap() {
            assert_eq!(
                validate_relative_path(
                    case["path"].as_str().unwrap().into(),
                    case["allowRoot"].as_bool().unwrap()
                )
                .is_ok(),
                case["valid"].as_bool().unwrap()
            );
        }
    }
}
