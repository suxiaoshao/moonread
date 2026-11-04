use super::*;
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
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ResolvedThemes {
    pub app: ResolvedTheme,
    pub reader: ResolvedTheme,
    pub reader_texture: ResolvedReaderTexture,
}
