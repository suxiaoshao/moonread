use moonread_core::*;

#[test]
fn all_palettes_are_readable_including_increased_contrast() {
    for palette in builtin_theme_palettes() {
        assert!(theme_colors_readable(palette.colors), "{}", palette.id);
        assert!(
            theme_colors_readable(palette.high_contrast),
            "{} high contrast",
            palette.id
        );
    }
}

#[test]
fn ink_must_be_readable_on_accent_surface() {
    // User messages put ink on accentSurface; a custom palette can edit it alone.
    let mut colors = builtin_theme_palettes()[0].colors.clone();
    assert!(theme_colors_readable(colors.clone()));
    colors.accent_surface = colors.ink;
    assert!(!theme_colors_readable(colors));
}

#[test]
fn reader_inherits_the_matching_app_slot_and_true_system_mode() {
    let mut value = default_theme_snapshot();
    value.preferences.app_mode = AppAppearanceMode::Light;
    value.preferences.app_dark = AppPaletteSource::Palette {
        id: "mint-dark".into(),
    };
    value.preferences.reader_mode = ReaderAppearanceMode::Dark;
    let plan = resolve_themes(value.clone(), ThemeAppearance::Light, false).unwrap();
    assert_eq!(plan.app.palette_id, "apricot-light");
    assert_eq!(plan.reader.palette_id, "mint-dark");
    value.preferences.app_mode = AppAppearanceMode::Dark;
    value.preferences.reader_mode = ReaderAppearanceMode::System;
    value.preferences.reader_light = ReaderPaletteSource::System;
    let plan = resolve_themes(value, ThemeAppearance::Light, true).unwrap();
    assert_eq!(plan.reader.appearance, ThemeAppearance::Light);
    assert!(plan.reader.colors.is_none());
    assert_eq!(plan.app.palette_id, "mint-dark");
}

#[test]
fn stored_theme_preferences_and_palettes_are_independent() {
    let snapshot = default_theme_snapshot();
    let preferences = encode_theme_preferences(snapshot.preferences).unwrap();
    let fields: serde_json::Value = serde_json::from_str(&preferences).unwrap();
    assert!(fields.get("palettes").is_none());
    assert!(fields.get("preferences").is_none());
    let mut palette = snapshot.palettes[0].clone();
    palette.id = "custom-independent".into();
    palette.name = "Independent".into();
    palette.custom = true;
    let encoded = encode_theme_palette(palette).unwrap();
    let fields: serde_json::Value = serde_json::from_str(&encoded).unwrap();
    assert!(fields.get("preferences").is_none());
    assert!(fields.get("palettes").is_none());
    let decoded = decode_theme_palette(encoded).unwrap();
    let mut restored = default_theme_snapshot();
    restored.preferences = decode_theme_preferences(preferences).unwrap();
    restored.palettes.push(decoded);
    assert!(resolve_themes(restored, ThemeAppearance::Light, false).is_ok());
}
