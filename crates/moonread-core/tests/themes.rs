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
fn reader_texture_preferences_migrate_and_preserve_published_values() {
    // Published 1.3 JSON, no new nested field; absence of a record is tested via Default separately.
    let old = r#"{"app_mode":"Dark","app_light":{"Palette":{"id":"mint-light"}},"app_dark":"System","reader_mode":"Light","reader_light":"System","reader_dark":{"Palette":{"id":"lilac-dark"}},"reduce_motion":true}"#;
    let baseline = decode_theme_preferences(old.into()).unwrap();
    assert!(baseline.reduce_motion);
    assert_eq!(baseline.reader_light, ReaderPaletteSource::System);
    assert!(
        baseline
            .reader_palette_textures
            .enabled_by_palette
            .values()
            .all(|v| !v)
    );
    assert!(
        default_theme_snapshot()
            .preferences
            .reader_palette_textures
            .enabled_by_palette
            .values()
            .all(|v| *v)
    );
    let mut fields: serde_json::Value = serde_json::from_str(old).unwrap();
    for id in ["paper-v1", "kraft-v1", "linen-v1", "grain-v1", "night-v1"] {
        fields["reader_light_texture"] = serde_json::json!({"id":id,"strength":"strong"});
        fields["reader_dark_texture"] = serde_json::Value::Null;
        let migrated = decode_theme_preferences(fields.to_string()).unwrap();
        for d in builtin_reader_textures() {
            assert_eq!(
                migrated.reader_palette_textures.enabled_by_palette[&d.palette_id],
                !d.palette_id.ends_with("-dark")
            );
        }
        assert_eq!(
            decode_theme_preferences(encode_theme_preferences(migrated.clone()).unwrap()).unwrap(),
            migrated
        );
        let mut snapshot = serde_json::to_value(default_theme_snapshot()).unwrap();
        snapshot["preferences"] = fields.clone();
        assert_eq!(
            decode_theme_snapshot(snapshot.to_string())
                .unwrap()
                .preferences,
            migrated
        );
    }
    fields["reader_light_texture"] = serde_json::json!({"id":"future-v9","strength":"light"});
    fields["reader_dark_texture"] = serde_json::json!({"id":"night-v1","strength":"future"});
    assert_eq!(
        decode_theme_preferences(fields.to_string()).unwrap(),
        baseline
    );
    fields["reader_light_texture"] = serde_json::json!({"id":"paper-v1"});
    fields["reader_dark_texture"] = serde_json::json!({"id":"linen-v1","strength":"medium"});
    let migrated = decode_theme_preferences(fields.to_string()).unwrap();
    assert!(
        migrated
            .reader_palette_textures
            .enabled_by_palette
            .values()
            .all(|v| *v)
    );
    let mut saved: serde_json::Value =
        serde_json::from_str(&encode_theme_preferences(migrated).unwrap()).unwrap();
    saved["reader_palette_textures"]["enabled_by_palette"]["apricot-light"] = false.into();
    // New map wins over legacy fields, independently per palette, including cache decode.
    let prefs = decode_theme_preferences(saved.to_string()).unwrap();
    assert!(!prefs.reader_palette_textures.enabled_by_palette["apricot-light"]);
    assert!(prefs.reader_palette_textures.enabled_by_palette["mint-light"]);
    assert_eq!(
        decode_theme_preferences(encode_theme_preferences(prefs.clone()).unwrap()).unwrap(),
        prefs
    );
    for invalid in [
        serde_json::json!({"version":2,"enabled_by_palette":{}}),
        serde_json::Value::Null,
        serde_json::json!({"version":1,"enabled_by_palette":"bad"}),
    ] {
        saved["reader_palette_textures"] = invalid;
        assert!(decode_theme_preferences(saved.to_string()).is_err());
        let mut snapshot = serde_json::to_value(default_theme_snapshot()).unwrap();
        snapshot["preferences"] = saved.clone();
        assert!(decode_theme_snapshot(snapshot.to_string()).is_err());
    }
    assert!(decode_theme_preferences("{".into()).is_err());
    let mut future = prefs;
    future.reader_palette_textures.version = 2;
    assert!(encode_theme_preferences(future).is_err());
}

#[test]
fn palette_texture_support_independence_and_resolved_inheritance() {
    let descriptors = builtin_reader_textures();
    assert_eq!(descriptors.len(), 7);
    assert_eq!(
        descriptors.iter().map(|d| d.layers.len()).sum::<usize>(),
        16
    );
    for descriptor in &descriptors {
        assert!((1..=4).contains(&descriptor.layers.len()));
        assert_eq!(descriptor.reference_short_side, 402);
        for layer in &descriptor.layers {
            assert!(layer.asset.reference_width > 0 && layer.asset.reference_height > 0);
            assert!((0.0..=1.0).contains(&layer.anchor_x) && (0.0..=1.0).contains(&layer.anchor_y));
            assert!(layer.max_width_fraction > 0.0 && layer.max_width_fraction <= 1.0);
            assert!(layer.max_height_fraction > 0.0 && layer.max_height_fraction <= 1.0);
        }
    }
    let mut snapshot = default_theme_snapshot();
    for palette in &snapshot.palettes {
        let resolved =
            reader_texture_for_palette(snapshot.preferences.clone(), palette.id.clone()).unwrap();
        assert_eq!(
            resolved.descriptor.is_some(),
            !["white-light", "black-dark"].contains(&palette.id.as_str())
        );
        assert_eq!(resolved.enabled, resolved.descriptor.is_some());
    }
    for id in ["system", "custom-apricot-light", "future-palette"] {
        assert!(
            reader_texture_for_palette(snapshot.preferences.clone(), id.into())
                .unwrap()
                .descriptor
                .is_none()
        );
        assert!(set_reader_palette_texture(snapshot.preferences.clone(), id.into(), true).is_err());
    }
    snapshot.preferences =
        set_reader_palette_texture(snapshot.preferences, "apricot-light".into(), false).unwrap();
    let plans = resolve_themes(snapshot.clone(), ThemeAppearance::Light, false).unwrap();
    assert_eq!(plans.reader_texture.palette_id, "apricot-light");
    assert!(!plans.reader_texture.enabled);
    snapshot.preferences.reader_mode = ReaderAppearanceMode::Dark;
    assert!(
        resolve_themes(snapshot.clone(), ThemeAppearance::Light, true)
            .unwrap()
            .reader_texture
            .enabled
    );
    snapshot.preferences.reader_mode = ReaderAppearanceMode::Light;
    snapshot.preferences.app_light = AppPaletteSource::Palette {
        id: "mint-light".into(),
    };
    assert_eq!(
        resolve_themes(snapshot.clone(), ThemeAppearance::Dark, false)
            .unwrap()
            .reader_texture
            .palette_id,
        "mint-light"
    );
    assert!(
        resolve_themes(snapshot.clone(), ThemeAppearance::Dark, false)
            .unwrap()
            .reader_texture
            .enabled
    );
    snapshot.preferences.reader_light = ReaderPaletteSource::System;
    assert!(
        resolve_themes(snapshot.clone(), ThemeAppearance::Dark, false)
            .unwrap()
            .reader_texture
            .descriptor
            .is_none()
    );
    let mut custom = snapshot.palettes[0].clone();
    custom.id = "custom-copy".into();
    custom.custom = true;
    snapshot.preferences.reader_light = ReaderPaletteSource::Palette {
        id: custom.id.clone(),
    };
    snapshot.palettes.push(custom);
    assert!(
        resolve_themes(snapshot.clone(), ThemeAppearance::Light, false)
            .unwrap()
            .reader_texture
            .descriptor
            .is_none()
    );
    snapshot
        .preferences
        .reader_palette_textures
        .enabled_by_palette
        .clear();
    assert!(
        reader_texture_for_palette(snapshot.preferences, "mint-dark".into())
            .unwrap()
            .enabled
    );
}
