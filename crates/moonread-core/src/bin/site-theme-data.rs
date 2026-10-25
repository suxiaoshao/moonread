//! Generate the website's read-only preview data from the app's existing rules.
use moonread_core::*;
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    error::Error,
    fs,
    path::{Path, PathBuf},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
type Names = BTreeMap<String, String>;

fn names(catalog: &Value, key: &str) -> Result<Names> {
    let entry = catalog["strings"]
        .get(key)
        .ok_or_else(|| format!("Missing app localization key: {key}"))?;
    let mut names = Names::new();
    for (site, app) in [("zh", "zh-Hans"), ("en", "en")] {
        let value = entry["localizations"][app]["stringUnit"]["value"]
            .as_str()
            .or_else(|| (catalog["sourceLanguage"] == app).then_some(key))
            .filter(|s| !s.is_empty())
            .ok_or_else(|| format!("Missing {app} translation: {key}"))?;
        names.insert(site.into(), value.into());
    }
    Ok(names)
}
fn id(value: impl Serialize) -> Result<String> {
    serde_json::to_value(value)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| "Expected a string identifier".into())
}
fn colors(value: impl Serialize) -> Result<BTreeMap<String, String>> {
    let value = serde_json::to_value(value)?;
    value
        .as_object()
        .ok_or("Expected theme colors")?
        .iter()
        .map(|(key, value)| {
            Ok((
                key.clone(),
                format!("#{:06x}", value.as_u64().ok_or("Expected RGB color")?),
            ))
        })
        .collect()
}
fn assets(root: &Path) -> Result<BTreeMap<String, Vec<u8>>> {
    let mut result = BTreeMap::new();
    for texture in reader_texture_ids() {
        let name = format!("ReaderTexture{texture:?}.imageset");
        let directory = root.join("ios/Moonread/Assets.xcassets").join(name);
        let contents: Value = serde_json::from_slice(&fs::read(directory.join("Contents.json"))?)?;
        let filename = contents["images"]
            .as_array()
            .ok_or("Missing texture images")?
            .iter()
            .find_map(|image| image["filename"].as_str())
            .ok_or("Missing texture source filename")?;
        // Original PNG bytes, never a web-specific recompression or new mask.
        result.insert(
            format!("{}.png", id(texture)?),
            fs::read(directory.join(filename))?,
        );
    }
    Ok(result)
}
fn document(root: &Path, textures: &BTreeMap<String, Vec<u8>>) -> Result<Value> {
    let catalog: Value =
        serde_json::from_slice(&fs::read(root.join("ios/Moonread/Localizable.xcstrings"))?)?;
    let strengths = reader_texture_strengths();
    let palettes: Vec<Value> = builtin_theme_palettes().into_iter().map(|palette| {
        let appearance = if palette.appearance == ThemeAppearance::Light { "light" } else { "dark" };
        let base = names(&catalog, &palette.name)?;
        let suffix = names(&catalog, if appearance == "light" { "浅色" } else { "深色" })?;
        let labels: Names = base.into_iter().map(|(lang, name)| {
            let label = format!("{name} · {}", suffix[&lang]); (lang, label)
        }).collect();
        let alpha: BTreeMap<String, f64> = strengths.iter().map(|&strength| {
            Ok((id(strength)?, reader_texture_alpha(palette.colors.paper, palette.colors.ink, strength)))
        }).collect::<Result<_>>()?;
        Ok(json!({"id":palette.id,"appearance":appearance,"name":labels,"colors":colors(palette.colors)?,"highContrast":colors(palette.high_contrast)?,"textureAlpha":alpha}))
    }).collect::<Result<_>>()?;
    let texture_data: Vec<Value> = reader_texture_ids().into_iter().map(|texture| {
        let key = match texture { ReaderTextureId::Paper => "宣纸", ReaderTextureId::Kraft => "牛皮纸", ReaderTextureId::Linen => "细麻布", ReaderTextureId::Grain => "颗粒" };
        let id = id(texture)?;
        let filename = format!("{id}.png");
        let digest: String = Sha256::digest(&textures[&filename]).iter().map(|byte| format!("{byte:02x}")).collect();
        Ok(json!({"id":id,"name":names(&catalog,key)?,"path":format!("textures/{filename}"),"sha256":digest}))
    }).collect::<Result<_>>()?;
    let strength_data: Vec<Value> = strengths
        .into_iter()
        .map(|strength| {
            let key = match strength {
                ReaderTextureStrength::Light => "淡",
                ReaderTextureStrength::Medium => "中",
                ReaderTextureStrength::Strong => "浓",
            };
            Ok(json!({"id":id(strength)?,"name":names(&catalog,key)?}))
        })
        .collect::<Result<_>>()?;
    let controls = reader_typography_controls();
    let defaults = default_reader_settings();
    let controls: BTreeMap<String, Value> = [
        (
            "fontSize",
            controls.font_size,
            defaults.font_size,
            "字号 · %lld pt",
        ),
        (
            "lineSpacing",
            controls.line_spacing,
            defaults.line_spacing,
            "行距 · %lld pt",
        ),
        (
            "paragraphSpacing",
            controls.paragraph_spacing,
            defaults.paragraph_spacing,
            "段间距 · %lld pt",
        ),
    ]
    .into_iter()
    .map(|(key, control, default, label)| {
        let labels = names(&catalog, label)?
            .into_iter()
            .map(|(lang, value)| {
                // The app's control title separates its label from the numeric value.
                let label = value.split(" · ").next().unwrap().to_owned();
                (lang, label)
            })
            .collect::<Names>();
        let mut value = serde_json::to_value(control)?;
        value["name"] = serde_json::to_value(labels)?;
        value["defaultValue"] = json!(default);
        Ok((key.into(), value))
    })
    .collect::<Result<_>>()?;
    let fonts: Vec<Value> = [
        (ReaderFont::System, "系统"),
        (ReaderFont::Serif, "宋体"),
        (ReaderFont::Rounded, "圆体"),
    ]
    .into_iter()
    .map(|(font, key)| Ok(json!({"id":id(font)?.to_lowercase(),"name":names(&catalog,key)?})))
    .collect::<Result<_>>()?;
    let labels: BTreeMap<String, Names> = [
        ("palette", "配色"),
        ("texture", "纸张纹理"),
        ("strength", "纹理强度"),
        ("font", "字体"),
        ("none", "无"),
        ("light", "浅色"),
        ("dark", "深色"),
    ]
    .into_iter()
    .map(|(id, key)| Ok((id.into(), names(&catalog, key)?)))
    .collect::<Result<_>>()?;
    Ok(
        json!({"schemaVersion":1,"palettes":palettes,"textures":texture_data,"strengths":strength_data,"fonts":fonts,"controls":controls,"tileSize":reader_texture_tile_size(),"labels":labels}),
    )
}
fn update(path: &Path, bytes: &[u8], write: bool) -> Result<()> {
    if write {
        fs::create_dir_all(path.parent().ok_or("Missing generated parent directory")?)?;
        fs::write(path, bytes)?;
    } else if fs::read(path).ok().as_deref() != Some(bytes) {
        return Err(format!(
            "Generated site asset is stale or missing: {}. Run site-theme-data --write.",
            path.display()
        )
        .into());
    }
    Ok(())
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let write = match args.as_slice() {
        [arg] if arg == "--write" => true,
        [arg] if arg == "--check" => false,
        _ => return Err("Usage: site-theme-data --write | --check".into()),
    };
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let textures = assets(&root)?;
    let mut bytes = serde_json::to_vec_pretty(&document(&root, &textures)?)?;
    bytes.push(b'\n');
    update(&root.join("docs/site/data/themes.json"), &bytes, write)?;
    let directory = root.join("docs/site/static/textures");
    for (name, bytes) in &textures {
        update(&directory.join(name), bytes, write)?;
    }
    let expected: BTreeSet<_> = textures.keys().cloned().collect();
    for entry in fs::read_dir(&directory)? {
        let entry = entry?;
        if !expected.contains(&entry.file_name().to_string_lossy().into_owned()) {
            if write && entry.file_type()?.is_file() {
                fs::remove_file(entry.path())?;
            } else {
                return Err(
                    format!("Unexpected generated texture: {}", entry.path().display()).into(),
                );
            }
        }
    }
    println!(
        "Site theme data {} ({} original texture PNGs).",
        if write { "written" } else { "is current" },
        textures.len()
    );
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
