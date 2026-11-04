use super::palettes::theme_colors_valid;
use super::*;
use crate::{ReaderError, Result};

fn json_error(e: serde_json::Error) -> ReaderError {
    ReaderError::Storage {
        message: e.to_string(),
    }
}
#[uniffi::export]
pub fn default_theme_snapshot() -> ThemeSnapshot {
    ThemeSnapshot {
        preferences: ThemePreferences::default(),
        palettes: builtin_theme_palettes(),
    }
}

/// A disposable presentation cache for the native first frame; not user-data storage.
#[uniffi::export]
pub fn encode_theme_snapshot(value: ThemeSnapshot) -> Result<String> {
    validate_snapshot(&value)?;
    serde_json::to_string(&value).map_err(json_error)
}
#[uniffi::export]
pub fn decode_theme_snapshot(json: String) -> Result<ThemeSnapshot> {
    if json.len() > 512 * 1024 {
        return Err(ReaderError::InvalidSettings);
    }
    let value: ThemeSnapshot = serde_json::from_str(&json).map_err(json_error)?;
    validate_snapshot(&value)?;
    Ok(value)
}

#[uniffi::export]
pub fn encode_theme_preferences(value: ThemePreferences) -> Result<String> {
    value.reader_palette_textures.validate()?;
    serde_json::to_string(&value).map_err(json_error)
}
#[uniffi::export]
pub fn decode_theme_preferences(json: String) -> Result<ThemePreferences> {
    if json.len() > 8192 {
        return Err(ReaderError::InvalidSettings);
    }
    serde_json::from_str(&json).map_err(json_error)
}
#[uniffi::export]
pub fn encode_theme_palette(value: ThemePalette) -> Result<String> {
    validate_palette(&value)?;
    serde_json::to_string(&value).map_err(json_error)
}
#[uniffi::export]
pub fn decode_theme_palette(json: String) -> Result<ThemePalette> {
    if json.len() > 8192 {
        return Err(ReaderError::InvalidSettings);
    }
    let value = serde_json::from_str(&json).map_err(json_error)?;
    validate_palette(&value)?;
    Ok(value)
}
fn validate_palette(palette: &ThemePalette) -> Result<()> {
    if palette.id.is_empty()
        || palette.name.trim().is_empty()
        || palette.name.chars().count() > 40
        || !theme_colors_valid(&palette.colors)
        || !theme_colors_valid(&palette.high_contrast)
    {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(())
}

fn validate_snapshot(value: &ThemeSnapshot) -> Result<()> {
    let mut ids = std::collections::HashSet::new();
    if value.palettes.len() > builtin_theme_palettes().len() + 64
        || value
            .palettes
            .iter()
            .any(|palette| !ids.insert(&palette.id) || validate_palette(palette).is_err())
    {
        return Err(ReaderError::InvalidSettings);
    }
    validate_preferences(&value.preferences, &value.palettes)
}

#[uniffi::export]
pub fn resolve_themes(
    value: ThemeSnapshot,
    system: ThemeAppearance,
    high_contrast: bool,
) -> Result<ResolvedThemes> {
    validate_preferences(&value.preferences, &value.palettes)?;
    let p = &value.preferences;
    let app_mode = match p.app_mode {
        AppAppearanceMode::System => system,
        AppAppearanceMode::Light => ThemeAppearance::Light,
        AppAppearanceMode::Dark => ThemeAppearance::Dark,
    };
    let reader_mode = match p.reader_mode {
        ReaderAppearanceMode::App => app_mode,
        ReaderAppearanceMode::System => system,
        ReaderAppearanceMode::Light => ThemeAppearance::Light,
        ReaderAppearanceMode::Dark => ThemeAppearance::Dark,
    };
    let app_source = |mode| {
        if mode == ThemeAppearance::Light {
            &p.app_light
        } else {
            &p.app_dark
        }
    };
    let palette = |mode, id: Option<&str>| -> Result<ResolvedTheme> {
        let colors = if let Some(id) = id {
            let palette = value
                .palettes
                .iter()
                .find(|v| v.id == id && v.appearance == mode)
                .ok_or(ReaderError::InvalidSettings)?;
            Some(if high_contrast {
                palette.high_contrast.clone()
            } else {
                palette.colors.clone()
            })
        } else {
            None
        };
        Ok(ResolvedTheme {
            appearance: mode,
            high_contrast,
            colors,
            palette_id: id.unwrap_or("system").into(),
        })
    };
    let app_id = |source: &AppPaletteSource| match source {
        AppPaletteSource::System => None,
        AppPaletteSource::Palette { id } => Some(id.clone()),
    };
    let reader = if reader_mode == ThemeAppearance::Light {
        &p.reader_light
    } else {
        &p.reader_dark
    };
    let reader_id = match reader {
        ReaderPaletteSource::App => app_id(app_source(reader_mode)),
        ReaderPaletteSource::System => None,
        ReaderPaletteSource::Palette { id } => Some(id.clone()),
    };
    let mut texture =
        reader_texture_for_palette(p.clone(), reader_id.clone().unwrap_or("system".into()))?;
    if value
        .palettes
        .iter()
        .any(|palette| palette.id == texture.palette_id && palette.custom)
    {
        texture.descriptor = None;
        texture.enabled = false;
    }
    Ok(ResolvedThemes {
        reader_texture: texture,
        app: palette(app_mode, app_id(app_source(app_mode)).as_deref())?,
        reader: palette(reader_mode, reader_id.as_deref())?,
    })
}

fn validate_preferences(p: &ThemePreferences, palettes: &[ThemePalette]) -> Result<()> {
    p.reader_palette_textures.validate()?;
    let valid = |id: &str, mode| palettes.iter().any(|v| v.id == id && v.appearance == mode);
    for (source, mode) in [
        (&p.app_light, ThemeAppearance::Light),
        (&p.app_dark, ThemeAppearance::Dark),
    ] {
        if let AppPaletteSource::Palette { id } = source
            && !valid(id, mode)
        {
            return Err(ReaderError::InvalidSettings);
        }
    }
    for (source, mode) in [
        (&p.reader_light, ThemeAppearance::Light),
        (&p.reader_dark, ThemeAppearance::Dark),
    ] {
        if let ReaderPaletteSource::Palette { id } = source
            && !valid(id, mode)
        {
            return Err(ReaderError::InvalidSettings);
        }
    }
    Ok(())
}
