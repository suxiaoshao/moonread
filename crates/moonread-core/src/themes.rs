//! Portable appearance preferences, palette validation and one-way inheritance.
use crate::{ReaderError, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ThemeAppearance {
    Light,
    Dark,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppAppearanceMode {
    System,
    Light,
    Dark,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ReaderAppearanceMode {
    App,
    System,
    Light,
    Dark,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppPaletteSource {
    System,
    Palette { id: String },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ReaderPaletteSource {
    App,
    System,
    Palette { id: String },
}

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
#[uniffi::export]
pub fn reader_texture_choice(id: ReaderTextureId) -> ReaderTextureChoice {
    ReaderTextureChoice {
        id,
        strength: ReaderTextureStrength::default(),
    }
}
#[uniffi::export]
pub fn reader_texture_ids() -> Vec<ReaderTextureId> {
    vec![
        ReaderTextureId::Paper,
        ReaderTextureId::Kraft,
        ReaderTextureId::Linen,
        ReaderTextureId::Grain,
    ]
}
#[uniffi::export]
pub fn reader_texture_strengths() -> Vec<ReaderTextureStrength> {
    vec![
        ReaderTextureStrength::Light,
        ReaderTextureStrength::Medium,
        ReaderTextureStrength::Strong,
    ]
}
#[uniffi::export]
pub fn reader_texture_alpha(paper: u32, ink: u32, strength: ReaderTextureStrength) -> f64 {
    let target = match strength {
        ReaderTextureStrength::Light => 0.015,
        ReaderTextureStrength::Medium => 0.025,
        ReaderTextureStrength::Strong => 0.035,
    };
    let paper = srgb_channels(paper);
    let ink = srgb_channels(ink);
    let lightness = oklab_lightness(paper);
    // Match normal source-over compositing in the standard sRGB tile. Only
    // the OKLab conversion linearizes the mixed RGB channels.
    let delta = |alpha: f64| {
        let mixed = std::array::from_fn(|i| paper[i] + (ink[i] - paper[i]) * alpha);
        (oklab_lightness(mixed) - lightness).abs()
    };
    // Custom paper/ink may be too close to reach the requested change. Use
    // the available endpoint; this is not a palette-saving restriction.
    if delta(1.0) <= target {
        return 1.0;
    }
    let (mut low, mut high) = (0.0, 1.0);
    for _ in 0..48 {
        let mid = (low + high) / 2.0;
        if delta(mid) < target {
            low = mid;
        } else {
            high = mid;
        }
    }
    (low + high) / 2.0
}

fn srgb_channels(color: u32) -> [f64; 3] {
    [16, 8, 0].map(|shift| f64::from((color >> shift) & 255) / 255.0)
}
fn srgb_linear(value: f64) -> f64 {
    if value <= 0.04045 {
        value / 12.92
    } else {
        ((value + 0.055) / 1.055).powf(2.4)
    }
}
fn oklab_lightness(srgb: [f64; 3]) -> f64 {
    // Björn Ottosson's 2021 linear-sRGB → OKLab matrices (L component).
    // https://bottosson.github.io/posts/oklab/#converting-from-linear-srgb-to-oklab
    let [r, g, b] = srgb.map(srgb_linear);
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ThemePreferences {
    pub app_mode: AppAppearanceMode,
    pub app_light: AppPaletteSource,
    pub app_dark: AppPaletteSource,
    pub reader_mode: ReaderAppearanceMode,
    pub reader_light: ReaderPaletteSource,
    pub reader_dark: ReaderPaletteSource,
    pub reduce_motion: bool,
    #[serde(default, deserialize_with = "decode_texture_choice")]
    pub reader_light_texture: Option<ReaderTextureChoice>,
    #[serde(default, deserialize_with = "decode_texture_choice")]
    pub reader_dark_texture: Option<ReaderTextureChoice>,
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
        }
    }
}

/// Opaque sRGB colors. Native selection remains an OS affordance; no UI objects persist.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ThemeColors {
    pub canvas: u32,
    pub surface: u32,
    pub raised: u32,
    pub input: u32,
    pub paper: u32,
    pub ink: u32,
    pub secondary: u32,
    pub disabled: u32,
    pub accent: u32,
    pub accent_surface: u32,
    pub on_accent: u32,
    pub border: u32,
    pub separator: u32,
    pub focus: u32,
    pub pressed: u32,
    pub selected: u32,
    pub annotation: u32,
    pub search: u32,
    pub search_current: u32,
    pub selection: u32,
    pub destructive: u32,
    pub on_destructive: u32,
    pub warning: u32,
    pub success: u32,
    pub moon: u32,
    pub maria: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ThemePalette {
    pub id: String,
    pub name: String,
    pub appearance: ThemeAppearance,
    pub custom: bool,
    pub colors: ThemeColors,
    pub high_contrast: ThemeColors,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ThemeSnapshot {
    pub preferences: ThemePreferences,
    pub palettes: Vec<ThemePalette>,
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ResolvedTheme {
    pub appearance: ThemeAppearance,
    pub high_contrast: bool,
    /// None requests native semantic system colors in this appearance scope.
    pub colors: Option<ThemeColors>,
    pub palette_id: String,
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ResolvedThemes {
    pub app: ResolvedTheme,
    pub reader: ResolvedTheme,
}

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
    Ok(ResolvedThemes {
        app: palette(app_mode, app_id(app_source(app_mode)).as_deref())?,
        reader: palette(reader_mode, reader_id.as_deref())?,
    })
}

fn validate_preferences(p: &ThemePreferences, palettes: &[ThemePalette]) -> Result<()> {
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

#[uniffi::export]
pub fn theme_color_contrast(foreground: u32, background: u32) -> f64 {
    fn luminance(c: u32) -> f64 {
        [16, 8, 0]
            .into_iter()
            .zip([0.2126, 0.7152, 0.0722])
            .map(|(shift, weight)| {
                let v = ((c >> shift) & 255) as f64 / 255.;
                weight * srgb_linear(v)
            })
            .sum()
    }
    let a = luminance(foreground);
    let b = luminance(background);
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

fn theme_colors_valid(c: &ThemeColors) -> bool {
    let values = [
        c.canvas,
        c.surface,
        c.raised,
        c.input,
        c.paper,
        c.ink,
        c.secondary,
        c.disabled,
        c.accent,
        c.accent_surface,
        c.on_accent,
        c.border,
        c.separator,
        c.focus,
        c.pressed,
        c.selected,
        c.annotation,
        c.search,
        c.search_current,
        c.selection,
        c.destructive,
        c.on_destructive,
        c.warning,
        c.success,
        c.moon,
        c.maria,
    ];
    values.iter().all(|v| *v <= 0xffffff)
}

#[uniffi::export]
pub fn theme_colors_readable(c: ThemeColors) -> bool {
    theme_colors_valid(&c)
        && [
            c.canvas,
            c.surface,
            c.raised,
            c.input,
            c.paper,
            c.annotation,
            c.search,
            c.search_current,
            c.selected,
            c.pressed,
            c.accent_surface,
        ]
        .into_iter()
        .all(|bg| theme_color_contrast(c.ink, bg) >= 4.5)
        && [c.canvas, c.surface, c.paper, c.input]
            .into_iter()
            .all(|bg| {
                theme_color_contrast(c.secondary, bg) >= 4.5
                    && theme_color_contrast(c.accent, bg) >= 4.5
            })
        && theme_color_contrast(c.on_accent, c.accent) >= 4.5
        && theme_color_contrast(c.on_destructive, c.destructive) >= 4.5
}

fn mix(a: u32, b: u32, amount: f64) -> u32 {
    [16, 8, 0].into_iter().fold(0, |result, shift| {
        let x = ((a >> shift) & 255) as f64;
        let y = ((b >> shift) & 255) as f64;
        result | (((x + (y - x) * amount).round() as u32) << shift)
    })
}
fn increased_contrast(c: &ThemeColors, appearance: ThemeAppearance) -> ThemeColors {
    let mut v = c.clone();
    let target = if appearance == ThemeAppearance::Light {
        0x000000
    } else {
        0xffffff
    };
    v.ink = mix(c.ink, target, 0.35);
    v.secondary = mix(c.secondary, target, 0.45);
    v.border = mix(c.border, target, 0.45);
    v.separator = v.border;
    v.accent = mix(c.accent, target, 0.15);
    v.focus = v.accent;
    // A custom palette can use unusual luminance relationships. Preserve a
    // readable original if enhancement would violate its other surfaces.
    if theme_colors_readable(v.clone()) {
        v
    } else {
        c.clone()
    }
}

#[uniffi::export]
pub fn builtin_theme_palettes() -> Vec<ThemePalette> {
    // Each row is independently art-directed. Only interaction surfaces and
    // accessibility variants derive from that row's own foreground/background.
    let rows = [
        (
            "apricot-light",
            "杏桃",
            ThemeAppearance::Light,
            [
                0xf7efe5, 0xfff9f2, 0xf5ecda, 0x403833, 0x6f6057, 0xa94f3d, 0xd4c2b5, 0xf0d896,
                0xd5e3ee, 0xb9d2e6, 0xb73548, 0x8a5b19, 0x376a50,
            ],
        ),
        (
            "apricot-dark",
            "杏桃",
            ThemeAppearance::Dark,
            [
                0x201b19, 0x2b2421, 0x241f1c, 0xd6c8ba, 0xb8a69a, 0xe6a68e, 0x665149, 0x51452f,
                0x283e50, 0x2f5068, 0xef9ca7, 0xdec088, 0x9dccad,
            ],
        ),
        (
            "mint-light",
            "薄荷",
            ThemeAppearance::Light,
            [
                0xedf4ef, 0xf7fcf8, 0xf4faf5, 0x2e4138, 0x5f7368, 0x2f725e, 0xadc6b8, 0xf0e3b4,
                0xdde8f8, 0xbdd2ee, 0xb2354d, 0x805d19, 0x2f725e,
            ],
        ),
        (
            "mint-dark",
            "薄荷",
            ThemeAppearance::Dark,
            [
                0x17231f, 0x20312a, 0x1c2924, 0xc5d5ca, 0x9eb8a9, 0x98cdb6, 0x426452, 0x454330,
                0x293f56, 0x2f506c, 0xf0a3b0, 0xdec593, 0x98cdb6,
            ],
        ),
        (
            "lilac-light",
            "雾紫",
            ThemeAppearance::Light,
            [
                0xf1eff8, 0xfaf8fe, 0xf8f5fc, 0x3b3649, 0x71687f, 0x71549d, 0xbfb2d0, 0xf4e2b5,
                0xd9e9ef, 0xb8d3e4, 0xad3550, 0x805c22, 0x386c58,
            ],
        ),
        (
            "lilac-dark",
            "雾紫",
            ThemeAppearance::Dark,
            [
                0x211f2b, 0x2c2839, 0x262230, 0xd0c8df, 0xb2a5c4, 0xc3a6e5, 0x665479, 0x4c4035,
                0x283f50, 0x2d546c, 0xefa0b6, 0xdec08d, 0xa0cdb8,
            ],
        ),
        (
            "black-dark",
            "纯黑夜间",
            ThemeAppearance::Dark,
            [
                0x000000, 0x101010, 0x000000, 0xb8b8b8, 0x939393, 0x9fbde5, 0x545454, 0x302b1e,
                0x192c3b, 0x253c50, 0xef9ca7, 0xdec088, 0x9dccad,
            ],
        ),
        (
            "white-light",
            "素白",
            ThemeAppearance::Light,
            [
                0xf4f4f4, 0xffffff, 0xffffff, 0x303030, 0x606060, 0x315e8a, 0xb9bec4, 0xf3e3ae,
                0xddebf5, 0xbfd7eb, 0xb73548, 0x805c22, 0x386c58,
            ],
        ),
        (
            "bean-light",
            "豆沙绿",
            ThemeAppearance::Light,
            [
                0xdce6d7, 0xeaf0e5, 0xdce8d1, 0x303b2d, 0x55614e, 0x386441, 0xa4b49b, 0xede0aa,
                0xd0e2eb, 0xabcad9, 0xac3446, 0x74551d, 0x376343,
            ],
        ),
    ];
    rows.into_iter()
        .map(|(id, name, appearance, r)| {
            let dark = appearance == ThemeAppearance::Dark;
            let [
                canvas,
                surface,
                paper,
                ink,
                secondary,
                accent,
                border,
                annotation,
                search,
                search_current,
                destructive,
                warning,
                success,
            ] = r;
            let colors = ThemeColors {
                canvas,
                surface,
                raised: mix(surface, ink, 0.025),
                input: mix(surface, canvas, 0.5),
                paper,
                ink,
                secondary,
                disabled: mix(secondary, canvas, 0.4),
                accent,
                accent_surface: mix(surface, accent, 0.12),
                on_accent: if dark { 0x211e24 } else { 0xffffff },
                border,
                separator: mix(border, surface, 0.45),
                focus: accent,
                pressed: mix(surface, accent, 0.12),
                selected: mix(surface, accent, 0.08),
                annotation,
                search,
                search_current,
                selection: accent,
                destructive,
                on_destructive: if dark { 0x211e24 } else { 0xffffff },
                warning,
                success,
                moon: if dark { 0xb1b1a8 } else { 0x8c9189 },
                maria: if dark { 0x717e89 } else { 0x596b7a },
            };
            ThemePalette {
                id: id.into(),
                name: name.into(),
                appearance,
                custom: false,
                high_contrast: increased_contrast(&colors, appearance),
                colors,
            }
        })
        .collect()
}

#[uniffi::export]
pub fn make_theme_palette(
    id: String,
    name: String,
    appearance: ThemeAppearance,
    colors: ThemeColors,
) -> Result<ThemePalette> {
    let name = name.trim().to_owned();
    if name.is_empty() || name.chars().count() > 40 || !theme_colors_valid(&colors) {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(ThemePalette {
        id,
        name,
        appearance,
        custom: true,
        high_contrast: increased_contrast(&colors, appearance),
        colors,
    })
}

#[cfg(test)]
mod texture_tests {
    use super::*;

    #[test]
    fn textures_share_perceptual_strength_across_all_builtin_palettes() {
        assert_eq!(
            reader_texture_ids(),
            vec![
                ReaderTextureId::Paper,
                ReaderTextureId::Kraft,
                ReaderTextureId::Linen,
                ReaderTextureId::Grain
            ]
        );
        for id in reader_texture_ids() {
            assert_eq!(
                reader_texture_choice(id).strength,
                ReaderTextureStrength::Light
            );
        }
        assert!((oklab_lightness([1.0; 3]) - 1.0).abs() < 1e-7);
        assert_eq!(oklab_lightness([0.0; 3]), 0.0);
        assert!((oklab_lightness([1.0, 0.0, 0.0]) - 0.6279553606).abs() < 1e-7);
        for palette in builtin_theme_palettes() {
            for colors in [palette.colors, palette.high_contrast] {
                let paper = srgb_channels(colors.paper);
                let ink = srgb_channels(colors.ink);
                for (strength, target) in reader_texture_strengths()
                    .into_iter()
                    .zip([0.015, 0.025, 0.035])
                {
                    let alpha = reader_texture_alpha(colors.paper, colors.ink, strength);
                    assert!(
                        (0.0..=1.0).contains(&alpha),
                        "{} {strength:?}: {alpha}",
                        palette.id
                    );
                    let mixed = std::array::from_fn(|i| paper[i] * (1.0 - alpha) + ink[i] * alpha);
                    let delta = (oklab_lightness(mixed) - oklab_lightness(paper)).abs();
                    assert!(
                        (delta - target).abs() < 1e-7,
                        "{} {strength:?}: ΔL={delta}",
                        palette.id
                    );
                }
            }
        }
    }
}
