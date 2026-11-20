use super::{MetadataBook, MetadataDiagnostic};
use serde::{
    Deserialize, Deserializer,
    de::{self, MapAccess, SeqAccess, Visitor},
};
use serde_json::{Map, Number, Value};
use std::{collections::HashSet, fmt};

pub(super) fn diagnostic(
    code: &str,
    field: Option<&str>,
    sha: Option<&str>,
    message: &str,
) -> MetadataDiagnostic {
    MetadataDiagnostic {
        source_line: None,
        record_index: None,
        code: code.into(),
        field: field.map(Into::into),
        content_sha256: sha.map(Into::into),
        message: message.into(),
    }
}

/// serde_json's default Value silently accepts duplicate keys. Keep that decision
/// at the format boundary, including nested/unknown objects, before any edits.
pub(super) struct StrictValue(pub Value);
impl<'de> Deserialize<'de> for StrictValue {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct Strict;
        impl<'de> Visitor<'de> for Strict {
            type Value = StrictValue;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("JSON value without duplicate keys")
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> std::result::Result<Self::Value, E> {
                Ok(StrictValue(Value::Bool(v)))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> std::result::Result<Self::Value, E> {
                Ok(StrictValue(Value::Number(v.into())))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> std::result::Result<Self::Value, E> {
                Ok(StrictValue(Value::Number(v.into())))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> std::result::Result<Self::Value, E> {
                Ok(StrictValue(Value::Number(
                    Number::from_f64(v).ok_or_else(|| E::custom("invalid JSON number"))?,
                )))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> std::result::Result<Self::Value, E> {
                Ok(StrictValue(Value::String(v.into())))
            }
            fn visit_string<E: de::Error>(self, v: String) -> std::result::Result<Self::Value, E> {
                Ok(StrictValue(Value::String(v)))
            }
            fn visit_unit<E: de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(StrictValue(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut a: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut v = Vec::new();
                while let Some(StrictValue(value)) = a.next_element()? {
                    v.push(value);
                }
                Ok(StrictValue(Value::Array(v)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut a: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut v = Map::new();
                while let Some(key) = a.next_key::<String>()? {
                    if v.contains_key(&key) {
                        return Err(de::Error::custom("duplicate JSON key"));
                    }
                    v.insert(key, a.next_value::<StrictValue>()?.0);
                }
                Ok(StrictValue(Value::Object(v)))
            }
        }
        d.deserialize_any(Strict)
    }
}

pub(super) fn book(
    mut value: Value,
) -> std::result::Result<(MetadataBook, Vec<MetadataDiagnostic>), Box<MetadataDiagnostic>> {
    let Some(map) = value.as_object_mut() else {
        return Err(Box::new(diagnostic(
            "invalid_record",
            None,
            None,
            "小说信息必须是对象",
        )));
    };
    let sha = map
        .get("content_sha256")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .filter(|s| crate::parse_sha256(s.clone()).is_ok());
    let err = |field: &str, message: &str| {
        Box::new(diagnostic(
            "invalid_field",
            Some(field),
            sha.as_deref(),
            message,
        ))
    };
    if map.get("v").and_then(Value::as_f64) != Some(1.0) {
        return Err(Box::new(diagnostic(
            "unsupported_version",
            Some("v"),
            sha.as_deref(),
            "不支持此条小说信息的版本",
        )));
    }
    map.insert("v".into(), Value::from(1));
    if sha
        .as_ref()
        .is_none_or(|s| crate::parse_sha256(s.clone()).is_err())
    {
        return Err(err("content_sha256", "正文身份必须是64位小写十六进制"));
    }
    // References are not selectors or writable fields, even if malformed.
    map.remove("reference");
    let mut warnings = Vec::new();
    for name in map.keys() {
        match name.as_str() {
            "v" | "content_sha256" | "title" | "author" | "tags" | "description" | "cover"
            | "reading_state" | "clear" | "requires" => {}
            "series" | "authors" => warnings.push(diagnostic(
                "unsupported_field",
                Some(name),
                sha.as_deref(),
                "暂不支持此字段，未导入",
            )),
            _ => warnings.push(diagnostic(
                "unknown_field",
                None,
                sha.as_deref(),
                "忽略未知可选字段",
            )),
        }
    }
    for field in ["title", "author", "description", "cover", "reading_state"] {
        if let Some(v) = map.get(field) {
            let Some(s) = v.as_str() else {
                return Err(err(field, "请提供字符串；缺字段表示保持不变，null不能清空"));
            };
            if s.trim().is_empty() {
                return Err(err(field, "请删除字段以保持不变，或用clear清空"));
            }
        }
    }
    for field in ["tags", "clear", "requires"] {
        if let Some(v) = map.get(field) {
            let Some(a) = v.as_array() else {
                return Err(err(field, "请提供字符串数组，null不能清空"));
            };
            if a.iter().any(|v| !v.is_string()) {
                return Err(err(field, "数组成员必须是字符串"));
            }
        }
    }
    let result: MetadataBook =
        serde_json::from_value(value).map_err(|_| err("record", "小说信息结构无法读取"))?;
    let mut clear = HashSet::new();
    for field in &result.clear {
        if !["author", "tags", "description", "cover"].contains(&field.as_str())
            || !clear.insert(field)
        {
            return Err(err("clear", "clear包含未知或重复字段"));
        }
        let assigned = match field.as_str() {
            "author" => result.author.is_some(),
            "tags" => result.tags.is_some(),
            "description" => result.description.is_some(),
            "cover" => result.cover.is_some(),
            _ => false,
        };
        if assigned {
            return Err(err(field, "同一字段不能同时赋值和清空"));
        }
    }
    if result.tags.as_ref().is_some_and(|t| t.len() > 100) {
        return Err(err("tags", "标签数量超过现有编辑上限"));
    }
    if result
        .reading_state
        .as_ref()
        .is_some_and(|s| !["unread", "reading", "finished", "paused"].contains(&s.as_str()))
    {
        return Err(err("reading_state", "未知阅读状态，未当作未读处理"));
    }
    if !result.requires.is_empty() {
        return Err(Box::new(diagnostic(
            "unsupported_feature",
            Some("requires"),
            sha.as_deref(),
            "此条要求App尚未支持的能力，未导入",
        )));
    }
    Ok((result, warnings))
}
