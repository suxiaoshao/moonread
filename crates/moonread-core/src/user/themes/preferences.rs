use super::*;
use crate::{ReaderError, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ReaderTextureId {
    #[serde(rename = "paper-v1")]
    Paper,
    #[serde(rename = "kraft-v1")]
    Kraft,
    #[serde(rename = "linen-v1")]
    Linen,
    #[serde(rename = "grain-v1", alias = "night-v1")]
    Grain,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum ReaderTextureStrength {
    #[default]
    Light,
    Medium,
    Strong,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderTextureChoice {
    pub id: ReaderTextureId,
    #[serde(default)]
    pub strength: ReaderTextureStrength,
}
fn decode_texture_choice<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Option<ReaderTextureChoice>, D::Error> {
    Ok(Option::<serde_json::Value>::deserialize(decoder)?
        .and_then(|value| serde_json::from_value(value).ok()))
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderPaletteTexturePreferences {
    pub version: u32,
    pub enabled_by_palette: HashMap<String, bool>,
}
impl Default for ReaderPaletteTexturePreferences {
    fn default() -> Self {
        Self::seed(true, true)
    }
}
impl ReaderPaletteTexturePreferences {
    fn seed(light: bool, dark: bool) -> Self {
        // Seed every supported palette in the old appearance slot, once on decode.
        // Afterwards only the new per-ID map is authoritative.
        Self {
            version: 1,
            enabled_by_palette: builtin_reader_textures()
                .into_iter()
                .map(|d| {
                    let enabled = if d.palette_id.ends_with("-dark") {
                        dark
                    } else {
                        light
                    };
                    (d.palette_id, enabled)
                })
                .collect(),
        }
    }
    pub(super) fn validate(&self) -> Result<()> {
        if self.version != 1 {
            return Err(ReaderError::InvalidSettings);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(try_from = "StoredThemePreferences")]
pub struct ThemePreferences {
    pub app_mode: AppAppearanceMode,
    pub app_light: AppPaletteSource,
    pub app_dark: AppPaletteSource,
    pub reader_mode: ReaderAppearanceMode,
    pub reader_light: ReaderPaletteSource,
    pub reader_dark: ReaderPaletteSource,
    pub reduce_motion: bool,
    pub reader_light_texture: Option<ReaderTextureChoice>,
    pub reader_dark_texture: Option<ReaderTextureChoice>,
    pub reader_palette_textures: ReaderPaletteTexturePreferences,
}

#[derive(Deserialize)]
struct StoredThemePreferences {
    app_mode: AppAppearanceMode,
    app_light: AppPaletteSource,
    app_dark: AppPaletteSource,
    reader_mode: ReaderAppearanceMode,
    reader_light: ReaderPaletteSource,
    reader_dark: ReaderPaletteSource,
    reduce_motion: bool,
    #[serde(default, deserialize_with = "decode_texture_choice")]
    reader_light_texture: Option<ReaderTextureChoice>,
    #[serde(default, deserialize_with = "decode_texture_choice")]
    reader_dark_texture: Option<ReaderTextureChoice>,
    #[serde(default, deserialize_with = "decode_palette_textures")]
    reader_palette_textures: Option<ReaderPaletteTexturePreferences>,
}
fn decode_palette_textures<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Option<ReaderPaletteTexturePreferences>, D::Error> {
    // Missing is legacy; a present null/broken structure is not a new installation.
    ReaderPaletteTexturePreferences::deserialize(decoder).map(Some)
}
impl TryFrom<StoredThemePreferences> for ThemePreferences {
    type Error = &'static str;
    fn try_from(value: StoredThemePreferences) -> std::result::Result<Self, Self::Error> {
        let textures = value.reader_palette_textures.unwrap_or_else(|| {
            ReaderPaletteTexturePreferences::seed(
                value.reader_light_texture.is_some(),
                value.reader_dark_texture.is_some(),
            )
        });
        if textures.version != 1 {
            return Err("Unsupported reader palette texture preferences version");
        }
        Ok(Self {
            app_mode: value.app_mode,
            app_light: value.app_light,
            app_dark: value.app_dark,
            reader_mode: value.reader_mode,
            reader_light: value.reader_light,
            reader_dark: value.reader_dark,
            reduce_motion: value.reduce_motion,
            reader_light_texture: value.reader_light_texture,
            reader_dark_texture: value.reader_dark_texture,
            reader_palette_textures: textures,
        })
    }
}

impl Default for ThemePreferences {
    fn default() -> Self {
        Self {
            app_mode: AppAppearanceMode::System,
            app_light: AppPaletteSource::Palette {
                id: "apricot-light".into(),
            },
            app_dark: AppPaletteSource::Palette {
                id: "apricot-dark".into(),
            },
            reader_mode: ReaderAppearanceMode::App,
            reader_light: ReaderPaletteSource::App,
            reader_dark: ReaderPaletteSource::App,
            reduce_motion: false,
            reader_light_texture: None,
            reader_dark_texture: None,
            reader_palette_textures: ReaderPaletteTexturePreferences::default(),
        }
    }
}
