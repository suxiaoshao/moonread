use moonread_core::*;

#[test]
fn builtin_palettes_are_readable_and_preserve_custom_capacity() {
    let palettes = builtin_theme_palettes();
    for palette in &palettes {
        assert!(
            theme_colors_readable(palette.colors.clone()),
            "{} standard",
            palette.id
        );
        assert!(
            theme_colors_readable(palette.high_contrast.clone()),
            "{} high contrast",
            palette.id
        );
    }
    for id in ["black-dark", "white-light", "bean-light"] {
        assert!(palettes.iter().any(|palette| palette.id == id), "{id}");
    }
    assert_eq!(
        palettes
            .iter()
            .find(|palette| palette.id == "black-dark")
            .unwrap()
            .colors
            .paper,
        0x000000
    );
    let mut snapshot = default_theme_snapshot();
    for index in 0..64 {
        let mut custom = palettes[0].clone();
        custom.id = format!("custom-capacity-{index}");
        custom.name = format!("Custom {index}");
        custom.custom = true;
        snapshot.palettes.push(custom);
    }
    let encoded = encode_theme_snapshot(snapshot.clone()).unwrap();
    assert_eq!(decode_theme_snapshot(encoded).unwrap(), snapshot);
    let mut extra = palettes[0].clone();
    extra.id = "custom-over-capacity".into();
    extra.custom = true;
    snapshot.palettes.push(extra);
    assert!(encode_theme_snapshot(snapshot).is_err());

    // User messages put ink on accentSurface; a custom palette can edit it alone.
    let mut colors = builtin_theme_palettes()[0].colors.clone();
    assert!(theme_colors_readable(colors.clone()));
    colors.accent_surface = colors.ink;
    assert!(!theme_colors_readable(colors));
    let mut body = builtin_theme_palettes()[0].colors.clone();
    body.paper = body.ink;
    assert!(
        !theme_colors_readable(body.clone()),
        "body ink against paper"
    );
    let custom = make_theme_palette(
        "custom-low".into(),
        "Low contrast".into(),
        ThemeAppearance::Light,
        body,
    )
    .unwrap();
    assert_eq!(
        decode_theme_palette(encode_theme_palette(custom.clone()).unwrap()).unwrap(),
        custom
    );
    let mut invalid = custom;
    invalid.colors.ink = 0xff000000;
    assert!(
        encode_theme_palette(invalid).is_err(),
        "RGB format limits still apply"
    );
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

#[test]
fn reader_texture_preferences_migrate_and_unknown_choices_become_none() {
    let old = r#"{"app_mode":"Dark","app_light":{"Palette":{"id":"mint-light"}},"app_dark":"System","reader_mode":"Light","reader_light":"System","reader_dark":{"Palette":{"id":"lilac-dark"}},"reduce_motion":true}"#;
    let mut prefs = decode_theme_preferences(old.into()).unwrap();
    assert_eq!(prefs.reader_light_texture, None);
    assert_eq!(prefs.reader_dark_texture, None);
    assert_eq!(prefs.app_mode, AppAppearanceMode::Dark);
    assert_eq!(
        prefs.app_light,
        AppPaletteSource::Palette {
            id: "mint-light".into()
        }
    );
    assert_eq!(prefs.reader_light, ReaderPaletteSource::System);
    assert!(prefs.reduce_motion);
    let baseline = prefs.clone();
    prefs.reader_light_texture = Some(ReaderTextureChoice {
        id: ReaderTextureId::Paper,
        strength: ReaderTextureStrength::Medium,
    });
    prefs.reader_dark_texture = Some(ReaderTextureChoice {
        id: ReaderTextureId::Grain,
        strength: ReaderTextureStrength::Strong,
    });
    let encoded = encode_theme_preferences(prefs.clone()).unwrap();
    assert_eq!(decode_theme_preferences(encoded.clone()).unwrap(), prefs);
    let mut fields: serde_json::Value = serde_json::from_str(&encoded).unwrap();
    fields["reader_dark_texture"] = serde_json::json!({"id":"night-v1","strength":"strong"});
    let migrated = decode_theme_preferences(fields.to_string()).unwrap();
    assert_eq!(migrated, prefs);
    let migrated = encode_theme_preferences(migrated).unwrap();
    assert!(migrated.contains("grain-v1"));
    assert!(!migrated.contains("night-v1"));
    fields["reader_light_texture"] = serde_json::json!({"id":"future-v9","strength":"light"});
    fields["reader_dark_texture"] = serde_json::json!({"id":"night-v1","strength":"future"});
    let decoded = decode_theme_preferences(fields.to_string()).unwrap();
    assert_eq!(decoded, baseline);
    assert!(
        !encode_theme_preferences(decoded)
            .unwrap()
            .contains("future")
    );
    fields["reader_light_texture"] = serde_json::json!({"id":"paper-v1"});
    fields
        .as_object_mut()
        .unwrap()
        .remove("reader_dark_texture");
    let decoded = decode_theme_preferences(fields.to_string()).unwrap();
    assert_eq!(
        decoded.reader_light_texture.unwrap().strength,
        ReaderTextureStrength::Light
    );
    assert_eq!(decoded.reader_dark_texture, None);
    assert!(decode_theme_preferences("{".into()).is_err());
    // The disposable first-frame snapshot embeds the same backwards-compatible preferences.
    let mut snapshot = serde_json::to_value(default_theme_snapshot()).unwrap();
    snapshot["preferences"] = serde_json::from_str(old).unwrap();
    assert_eq!(
        decode_theme_snapshot(snapshot.to_string())
            .unwrap()
            .preferences,
        baseline
    );
}
