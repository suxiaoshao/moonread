use super::*;
use crate::{ReaderError, Result};
use serde::{Deserialize, Serialize};

/// Published 1.3 texture values are decode-only compatibility fields.
/// Runtime support and artwork parameters have one owner: this descriptor list.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum ReaderTextureBlend {
    Normal,
    Multiply,
    Screen,
    SoftLight,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderTextureAsset {
    pub name: String,
    pub reference_width: u32,
    pub reference_height: u32,
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum ReaderTexturePlacement {
    Cover,
    Edge,
    Fit,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderTextureLayer {
    pub asset: ReaderTextureAsset,
    pub placement: ReaderTexturePlacement,
    pub anchor_x: f64,
    pub anchor_y: f64,
    pub max_width_fraction: f64,
    pub max_height_fraction: f64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderTextureDescriptor {
    pub palette_id: String,
    pub reference_short_side: u32,
    pub layers: Vec<ReaderTextureLayer>,
    pub blend: ReaderTextureBlend,
    pub opacity: f64,
}
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum ResolvedReaderTexture {
    Unsupported { palette_id: String },
    Off { descriptor: ReaderTextureDescriptor },
    On { descriptor: ReaderTextureDescriptor },
}

impl ResolvedReaderTexture {
    pub fn descriptor(&self) -> Option<&ReaderTextureDescriptor> {
        match self {
            Self::Unsupported { .. } => None,
            Self::Off { descriptor } | Self::On { descriptor } => Some(descriptor),
        }
    }

    pub fn enabled(&self) -> bool {
        matches!(self, Self::On { .. })
    }

    pub fn palette_id(&self) -> &str {
        match self {
            Self::Unsupported { palette_id } => palette_id,
            Self::Off { descriptor } | Self::On { descriptor } => &descriptor.palette_id,
        }
    }
}
#[uniffi::export]
pub fn builtin_reader_textures() -> Vec<ReaderTextureDescriptor> {
    use ReaderTextureBlend::*;
    use ReaderTexturePlacement::*;
    let layer =
        |name: &str, width, height, placement, x, y, max_width, max_height| ReaderTextureLayer {
            asset: ReaderTextureAsset {
                name: format!("ReaderBackdrop{name}"),
                reference_width: width,
                reference_height: height,
            },
            placement,
            anchor_x: x,
            anchor_y: y,
            max_width_fraction: max_width,
            max_height_fraction: max_height,
        };
    [
        (
            "apricot-light",
            Multiply,
            0.22,
            vec![layer("PaperLight", 402, 874, Cover, 0.5, 0.5, 1.0, 1.0)],
        ),
        (
            "apricot-dark",
            SoftLight,
            0.65,
            vec![layer("PaperDark", 402, 874, Cover, 0.5, 0.5, 1.0, 1.0)],
        ),
        (
            "bean-light",
            Multiply,
            0.42,
            vec![
                layer("BambooLeft", 198, 874, Fit, 0.0, 1.0, 0.5, 1.0),
                layer("BambooRight", 157, 874, Fit, 1.0, 1.0, 0.5, 1.0),
            ],
        ),
        (
            "mint-light",
            Multiply,
            0.32,
            vec![
                layer("MintLightTopLeft", 220, 335, Fit, 0.0, 0.0, 0.5, 0.5),
                layer("MintLightTopRight", 142, 265, Fit, 1.0, 0.0, 0.5, 0.5),
                layer("MintLightBottomLeft", 112, 244, Fit, 0.0, 1.0, 0.5, 0.5),
                layer("MintLightBottomRight", 322, 614, Fit, 1.0, 1.0, 0.5, 0.5),
            ],
        ),
        (
            "mint-dark",
            Normal,
            0.20,
            vec![
                layer("MintDarkTopLeft", 220, 335, Fit, 0.0, 0.0, 0.5, 0.5),
                layer("MintDarkTopRight", 142, 265, Fit, 1.0, 0.0, 0.5, 0.5),
                layer("MintDarkBottomLeft", 112, 244, Fit, 0.0, 1.0, 0.5, 0.5),
                layer("MintDarkBottomRight", 322, 614, Fit, 1.0, 1.0, 0.5, 0.5),
            ],
        ),
        (
            "lilac-light",
            Multiply,
            0.70,
            vec![
                layer("MistLightTop", 402, 306, Edge, 0.0, 0.0, 1.0, 0.38),
                layer("MistLightBottom", 402, 306, Edge, 0.0, 1.0, 1.0, 0.38),
            ],
        ),
        (
            "lilac-dark",
            Screen,
            0.20,
            vec![
                layer("MistDarkTop", 402, 306, Edge, 0.0, 0.0, 1.0, 0.38),
                layer("MistDarkBottom", 402, 306, Edge, 0.0, 1.0, 1.0, 0.38),
            ],
        ),
    ]
    .into_iter()
    .map(|(id, blend, opacity, layers)| ReaderTextureDescriptor {
        palette_id: id.into(),
        reference_short_side: 402,
        layers,
        blend,
        opacity,
    })
    .collect()
}
#[uniffi::export]
pub fn reader_texture_for_palette(
    preferences: ThemePreferences,
    palette_id: String,
) -> Result<ResolvedReaderTexture> {
    preferences.reader_palette_textures.validate()?;
    let Some(descriptor) = builtin_reader_textures()
        .into_iter()
        .find(|d| d.palette_id == palette_id)
    else {
        return Ok(ResolvedReaderTexture::Unsupported { palette_id });
    };
    let enabled = preferences
        .reader_palette_textures
        .enabled_by_palette
        .get(&palette_id)
        .copied()
        .unwrap_or(true);
    Ok(if enabled {
        ResolvedReaderTexture::On { descriptor }
    } else {
        ResolvedReaderTexture::Off { descriptor }
    })
}
#[uniffi::export]
pub fn set_reader_palette_texture(
    mut preferences: ThemePreferences,
    palette_id: String,
    enabled: bool,
) -> Result<ThemePreferences> {
    let resolved = reader_texture_for_palette(preferences.clone(), palette_id.clone())?;
    if matches!(resolved, ResolvedReaderTexture::Unsupported { .. }) {
        return Err(ReaderError::InvalidSettings);
    }
    preferences
        .reader_palette_textures
        .enabled_by_palette
        .insert(palette_id, enabled);
    Ok(preferences)
}
