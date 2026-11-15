use moonread_core::*;

#[test]
fn settings_codec_preserves_device_preferences_and_validates_ranges() {
    let mut value = default_reader_settings();
    let controls = reader_typography_controls();
    assert_eq!(value.font_size, controls.font_size.default_value);
    assert_eq!(value.line_spacing, controls.line_spacing.default_value);
    assert_eq!(
        value.paragraph_spacing,
        controls.paragraph_spacing.default_value
    );
    value.keep_awake = true;
    value.font = ReaderFont::Serif;
    assert_eq!(
        decode_reader_settings(encode_reader_settings(value.clone()).unwrap()).unwrap(),
        value
    );
    value.font_size = controls.font_size.maximum;
    assert!(decode_reader_settings(encode_reader_settings(value.clone()).unwrap()).is_ok());
    value.font_size += controls.font_size.step;
    assert!(decode_reader_settings(encode_reader_settings(value).unwrap()).is_err());
}

#[test]
fn released_reader_settings_keep_their_values() {
    // Published 1.2 (10), 6ceef33: no wide-screen fields. Keep every old choice.
    let json = r#"{"mode":"Pages","font_size":24.0,"line_spacing":10.0,"font":"Serif","paragraph_spacing":9.0,"indent":"Original","horizontal_margin":20.0,"maximum_line_width":720.0,"keep_awake":true,"brightness":0.4,"orientation":"Portrait"}"#;
    let value = decode_reader_settings(json.to_owned()).unwrap();
    assert_eq!(value.mode, ReadingMode::Pages);
    assert_eq!(value.font_size, 24.0);
    assert_eq!(value.line_spacing, 10.0);
    assert_eq!(value.font, ReaderFont::Serif);
    assert_eq!(value.auto_reading_speed, 10.0);
    let control = auto_reading_control();
    assert_eq!(
        (control.minimum, control.maximum, control.step),
        (1.0, 30.0, 1.0)
    );
    for speed in [1.0, 30.0] {
        let mut next = value.clone();
        next.auto_reading_speed = speed;
        assert!(decode_reader_settings(encode_reader_settings(next).unwrap()).is_ok());
    }
    for speed in [0.0, 31.0, 9.5, f64::NAN] {
        let mut next = value.clone();
        next.auto_reading_speed = speed;
        assert!(decode_reader_settings(encode_reader_settings(next).unwrap()).is_err());
    }
    assert_eq!(auto_reading_em_per_minute(1.0).unwrap(), 150.0);
    assert!((auto_reading_em_per_minute(10.0).unwrap() - 570.44).abs() < 0.01);
    assert!((auto_reading_em_per_minute(20.0).unwrap() - 2516.48).abs() < 0.01);
    assert!((auto_reading_em_per_minute(30.0).unwrap() - 11101.28).abs() < 0.01);
    assert!(
        (auto_reading_em_per_minute(11.0).unwrap() / auto_reading_em_per_minute(10.0).unwrap()
            - 1.16)
            .abs()
            < 1e-12
    );
    assert!(auto_reading_em_per_minute(9.5).is_err());
    assert_eq!(value.imported_font, None);
    assert_eq!(value.paragraph_spacing, 9.0);
    assert_eq!(value.indent, ReadingIndent::Original);
    assert_eq!(value.horizontal_margin, 20.0);
    assert_eq!(value.maximum_line_width, 720.0);
    assert!(value.keep_awake);
    assert_eq!(value.brightness, Some(0.4));
    assert_eq!(value.orientation, ReadingOrientation::Portrait);
    assert_eq!(
        decode_reader_settings(encode_reader_settings(value.clone()).unwrap()).unwrap(),
        value
    );
}
