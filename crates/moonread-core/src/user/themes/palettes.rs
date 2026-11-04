use super::*;
use crate::{ReaderError, Result};

fn srgb_linear(value: f64) -> f64 {
    if value <= 0.04045 {
        value / 12.92
    } else {
        ((value + 0.055) / 1.055).powf(2.4)
    }
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

pub(super) fn theme_colors_valid(c: &ThemeColors) -> bool {
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
            "纸色",
            ThemeAppearance::Light,
            [
                0xf7efe5, 0xfff9f2, 0xf5ecda, 0x403833, 0x6f6057, 0xa94f3d, 0xd4c2b5, 0xf0d896,
                0xd5e3ee, 0xb9d2e6, 0xb73548, 0x8a5b19, 0x376a50,
            ],
        ),
        (
            "apricot-dark",
            "纸色",
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
            "竹绿",
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
