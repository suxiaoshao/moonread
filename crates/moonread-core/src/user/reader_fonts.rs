//! Device-local font resources. Core Text supplies faces; Rust owns stable IDs,
//! paths, de-duplication and the versioned manifest contract, not font metrics.
use crate::*;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ImportedReaderFont {
    pub resource_sha256: String,
    pub face: String,
}
impl ImportedReaderFont {
    pub(crate) fn valid(&self) -> bool {
        valid_sha(&self.resource_sha256) && !self.face.is_empty() && !self.face.contains('\0')
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderFontFace {
    pub postscript_name: String,
    pub display_name: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderFontResource {
    pub sha256: String,
    pub relative_path: String,
    pub source_name: String,
    pub faces: Vec<ReaderFontFace>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    schema_version: u32,
    resources: Vec<ReaderFontResource>,
}
#[uniffi::export]
pub fn make_reader_font_resource(
    sha256: String,
    extension: String,
    source_name: String,
    faces: Vec<ReaderFontFace>,
) -> Result<ReaderFontResource> {
    if !valid_sha(&sha256)
        || !["ttf", "otf", "ttc", "otc"].contains(&extension.as_str())
        || source_name.is_empty()
        || faces.is_empty()
    {
        return Err(ReaderError::InvalidSettings);
    }
    let mut names = HashSet::new();
    for face in &faces {
        if face.postscript_name.is_empty()
            || face.postscript_name.contains('\0')
            || face.display_name.is_empty()
            || !names.insert(&face.postscript_name)
        {
            return Err(ReaderError::InvalidSettings);
        }
    }
    Ok(ReaderFontResource {
        relative_path: format!("{sha256}.{extension}"),
        sha256,
        source_name,
        faces,
    })
}
fn validate(resources: &[ReaderFontResource]) -> Result<()> {
    let mut identities = HashSet::new();
    let mut names = HashSet::new();
    for resource in resources {
        let extension = resource
            .relative_path
            .rsplit('.')
            .next()
            .unwrap_or_default();
        let canonical = make_reader_font_resource(
            resource.sha256.clone(),
            extension.into(),
            resource.source_name.clone(),
            resource.faces.clone(),
        )?;
        if canonical != *resource || !identities.insert(&resource.sha256) {
            return Err(ReaderError::InvalidSettings);
        }
        for face in &resource.faces {
            if !names.insert(&face.postscript_name) {
                return Err(ReaderError::InvalidSettings);
            }
        }
    }
    Ok(())
}
#[uniffi::export]
pub fn encode_reader_font_manifest(resources: Vec<ReaderFontResource>) -> Result<String> {
    validate(&resources)?;
    serde_json::to_string(&Manifest {
        schema_version: 1,
        resources,
    })
    .map_err(|_| ReaderError::InvalidSettings)
}
#[uniffi::export]
pub fn decode_reader_font_manifest(json: String) -> Result<Vec<ReaderFontResource>> {
    let manifest: Manifest =
        serde_json::from_str(&json).map_err(|_| ReaderError::InvalidSettings)?;
    if manifest.schema_version != 1 {
        return Err(ReaderError::InvalidSettings);
    }
    validate(&manifest.resources)?;
    Ok(manifest.resources)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manifest_is_versioned_and_resources_keep_stable_safe_identity() {
        let resource = make_reader_font_resource(
            "a".repeat(64),
            "ttc".into(),
            "原创字体.ttc".into(),
            vec![ReaderFontFace {
                postscript_name: "Sample-Regular".into(),
                display_name: "Sample".into(),
            }],
        )
        .unwrap();
        assert_eq!(
            decode_reader_font_manifest(
                encode_reader_font_manifest(vec![resource.clone()]).unwrap()
            )
            .unwrap(),
            vec![resource.clone()]
        );
        assert!(encode_reader_font_manifest(vec![resource.clone(), resource.clone()]).is_err());
        let mut bad = resource.clone();
        bad.relative_path = "../outside.ttf".into();
        assert!(encode_reader_font_manifest(vec![bad]).is_err());
        assert!(
            decode_reader_font_manifest(r#"{"schemaVersion":2,"resources":[]}"#.into()).is_err()
        );
        let mut settings = default_reader_settings();
        settings.imported_font = Some(ImportedReaderFont {
            resource_sha256: resource.sha256,
            face: "Sample-Regular".into(),
        });
        assert_eq!(
            decode_reader_settings(encode_reader_settings(settings.clone()).unwrap()).unwrap(),
            settings
        );
        settings.imported_font.as_mut().unwrap().resource_sha256 = "bad".into();
        assert!(decode_reader_settings(encode_reader_settings(settings).unwrap()).is_err());
    }
}
