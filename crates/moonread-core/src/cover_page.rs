//! Extract only declared image resources; never fetch or expose page text.
use encoding_rs::{Encoding, UTF_8};
use scraper::{Html, Selector};
use serde_json::Value;
use url::Url;

const MAX_BYTES: usize = 2 * 1024 * 1024;
const MAX_IMAGES: usize = 4;

fn selector(value: &str) -> Selector {
    Selector::parse(value).expect("static selector")
}
fn resolve(base: &Url, value: &str) -> Option<Url> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    base.join(value)
        .ok()
        .filter(|url| matches!(url.scheme(), "http" | "https") && url.has_host())
}
fn declared_encoding(html: &Html) -> Option<&'static Encoding> {
    for meta in html.select(&selector("meta")) {
        if let Some(encoding) = meta
            .value()
            .attr("charset")
            .and_then(|s| Encoding::for_label(s.trim().as_bytes()))
        {
            return Some(encoding);
        }
        if meta
            .value()
            .attr("http-equiv")
            .is_some_and(|v| v.eq_ignore_ascii_case("content-type"))
        {
            for field in meta.value().attr("content").unwrap_or_default().split(';') {
                if let Some((key, value)) = field.split_once('=')
                    && key.trim().eq_ignore_ascii_case("charset")
                    && let Some(encoding) =
                        Encoding::for_label(value.trim().trim_matches(['\'', '"']).as_bytes())
                {
                    return Some(encoding);
                }
            }
        }
    }
    None
}
struct Images {
    base: Url,
    urls: Vec<String>,
}
impl Images {
    fn add(&mut self, value: &str) {
        if self.urls.len() >= MAX_IMAGES {
            return;
        }
        if let Some(url) = resolve(&self.base, value) {
            let url = url.to_string();
            if !self.urls.contains(&url) {
                self.urls.push(url);
            }
        }
    }
    fn json(&mut self, value: &Value, image: bool, depth: usize, budget: &mut usize) {
        if depth > 32 || *budget == 0 || self.urls.len() >= MAX_IMAGES {
            return;
        }
        *budget -= 1;
        match value {
            Value::String(s) if image => self.add(s),
            Value::Array(items) => {
                for item in items {
                    self.json(item, image, depth + 1, budget);
                    if *budget == 0 {
                        break;
                    }
                }
            }
            Value::Object(object) => {
                if image {
                    for key in ["url", "contentUrl"] {
                        if let Some(v) = object.get(key) {
                            self.json(v, true, depth + 1, budget);
                        }
                    }
                }
                if let Some(v) = object.get("image") {
                    self.json(v, true, depth + 1, budget);
                }
                if let Some(v) = object.get("@graph") {
                    self.json(v, false, depth + 1, budget);
                }
            }
            _ => {}
        }
    }
}

#[uniffi::export]
pub fn extract_page_images(
    body: Vec<u8>,
    response_url: String,
    charset: Option<String>,
    title: Option<String>,
) -> Vec<String> {
    let Ok(base) = Url::parse(&response_url) else {
        return vec![];
    };
    if !matches!(base.scheme(), "http" | "https") || !base.has_host() {
        return vec![];
    }
    let bytes = &body[..body.len().min(MAX_BYTES)];
    let encoding = charset
        .as_deref()
        .and_then(|s| Encoding::for_label(s.trim().as_bytes()))
        .or_else(|| Encoding::for_bom(bytes).map(|(e, _)| e))
        .or_else(|| declared_encoding(&Html::parse_document(&String::from_utf8_lossy(bytes))))
        .unwrap_or(UTF_8);
    let (decoded, _) = encoding.decode_without_bom_handling(bytes);
    let html = Html::parse_document(&decoded);
    let base = html
        .select(&selector("base[href]"))
        .find_map(|el| resolve(&base, el.value().attr("href")?))
        .unwrap_or(base);
    let mut images = Images { base, urls: vec![] };
    for names in [
        &["og:image", "og:image:secure_url", "og:image:url"][..],
        &["twitter:image", "twitter:image:src"][..],
    ] {
        for meta in html.select(&selector("meta")) {
            if ["property", "name"].iter().any(|key| {
                meta.value()
                    .attr(key)
                    .is_some_and(|v| names.iter().any(|name| v.eq_ignore_ascii_case(name)))
            }) && let Some(value) = meta.value().attr("content")
            {
                images.add(value);
            }
        }
    }
    for el in html.select(&selector("link, [itemprop]")) {
        let value = el.value();
        if value.name() == "link"
            && value.attr("rel").is_some_and(|v| {
                v.split_ascii_whitespace()
                    .any(|r| r.eq_ignore_ascii_case("image_src"))
            })
            && let Some(v) = value.attr("href")
        {
            images.add(v);
        }
        if value
            .attr("itemprop")
            .is_some_and(|v| v.split_ascii_whitespace().any(|p| p == "image"))
        {
            for key in ["content", "src", "href"] {
                if let Some(v) = value.attr(key) {
                    images.add(v);
                }
            }
        }
    }
    let mut budget = 4096;
    for el in html.select(&selector("script")) {
        if el
            .value()
            .attr("type")
            .is_some_and(|v| v.trim().eq_ignore_ascii_case("application/ld+json"))
            && let Ok(json) = serde_json::from_str::<Value>(&el.text().collect::<String>())
        {
            images.json(&json, false, 0, &mut budget);
        }
        if budget == 0 || images.urls.len() == MAX_IMAGES {
            break;
        }
    }
    let title = title.as_deref().map(str::trim).filter(|t| !t.is_empty());
    let mut fallback = 0;
    for el in html.select(&selector("img")) {
        let v = el.value();
        let matches_title = title.is_some_and(|t| v.attr("alt").is_some_and(|alt| alt.contains(t)));
        let matches_class = ["class", "id"].iter().any(|key| {
            v.attr(key).is_some_and(|s| {
                let s = s.to_ascii_lowercase();
                ["cover", "bookimg", "book-img", "mainpic"]
                    .iter()
                    .any(|key| s.contains(key))
            })
        });
        if (matches_title || matches_class)
            && let Some(url) = ["data-src", "data-original", "data-lazy-src", "src"]
                .iter()
                .find_map(|key| v.attr(key).and_then(|s| resolve(&images.base, s)))
        {
            let before = images.urls.len();
            images.add(url.as_str());
            fallback += usize::from(images.urls.len() > before);
            if fallback == 2 || images.urls.len() == MAX_IMAGES {
                break;
            }
        }
    }
    images.urls
}

#[cfg(test)]
mod tests {
    use super::*;
    fn extract(s: &str) -> Vec<String> {
        extract_page_images(
            s.as_bytes().to_vec(),
            "https://example.com/final/book/".into(),
            None,
            Some("星灯渡口".into()),
        )
    }
    #[test]
    fn metadata_base_priority_and_query() {
        assert_eq!(
            extract(
                r#"<base href="data:bad"><base href="../assets/"><base href="https://ignored.test/"><meta name="twitter:image" content="a?sig=A%2FB&z=1"><meta property="og:image" content="a?sig=A%2FB&amp;z=1"><meta property="og:image" content="//cdn.test/b">"#
            ),
            [
                "https://example.com/final/assets/a?sig=A%2FB&z=1",
                "https://cdn.test/b"
            ]
        );

        let html = r#"<img alt="星灯渡口" src="data:bad" data-src="/cover.jpg"><img id="cover" src="/placeholder" data-original="//cdn.test/real"><img class="cover" src="/third">"#;
        assert_eq!(
            extract(html),
            ["https://example.com/cover.jpg", "https://cdn.test/real"]
        );
        assert!(
            extract_page_images(
                b"<img alt='anything' src='/wrong'>".to_vec(),
                "https://example.com/".into(),
                None,
                Some("  ".into())
            )
            .is_empty()
        );
    }
    #[test]
    fn json_shapes_and_depth() {
        assert_eq!(extract(r#"<script type="application/ld+json">[{"@graph":[{"image":["/a",{"@type":"ImageObject","contentUrl":"/b"},{"url":"/c"}]}]},{"image":"/d"},{"image":"/e"}]</script>"#).len(), 4);
        let deep = format!(
            "<script type='application/ld+json'>{}{{\"image\":\"/bad\"}}{}</script>",
            "[".repeat(40),
            "]".repeat(40)
        );
        assert!(extract(&deep).is_empty());
    }
    #[test]
    fn gb18030_and_http_equiv() {
        let text = "<meta http-equiv='Content-Type' content='text/html; charset=gb18030'><img alt='星灯渡口' src='/a'>";
        let (bytes, _, _) = encoding_rs::GB18030.encode(text);
        assert_eq!(
            extract_page_images(
                bytes.into_owned(),
                "https://example.com/".into(),
                None,
                Some("星灯渡口".into())
            ),
            ["https://example.com/a"]
        );
    }
    #[test]
    fn limits_invalid_and_truncation() {
        assert!(
            extract("<meta property=og:image content='data:bad'><img src='/unmatched'>").is_empty()
        );
        assert_eq!(extract("<link rel=image_src href=/a><meta itemprop=image content=/b><img class=cover src=/c>" ).len(), 3);
        let html = format!(
            "{}<meta property=og:image content=/late>",
            " ".repeat(MAX_BYTES)
        );
        assert!(extract(&html).is_empty());
    }
}
