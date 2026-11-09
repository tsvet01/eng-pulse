//! JSON Schema tightening for provider structured-output modes.

use serde_json::Value;

/// Make a schemars schema acceptable to strict structured-output modes:
/// every object lists all properties as required and forbids extras, and
/// annotations providers reject (`$schema`, `title`, `format`) are dropped.
pub fn strict_schema(mut schema: Value) -> Value {
    tighten(&mut schema);
    schema
}

fn tighten(node: &mut Value) {
    let Value::Object(map) = node else {
        return;
    };
    for key in ["$schema", "title", "format"] {
        map.remove(key);
    }
    if let Some(Value::Object(props)) = map.get_mut("properties") {
        let names: Vec<Value> = props.keys().cloned().map(Value::String).collect();
        for prop in props.values_mut() {
            tighten(prop);
        }
        map.insert("required".into(), Value::Array(names));
        map.insert("additionalProperties".into(), Value::Bool(false));
    }
    match map.get_mut("items") {
        Some(Value::Array(items)) => items.iter_mut().for_each(tighten),
        Some(items) => tighten(items),
        None => {}
    }
    for key in ["anyOf", "oneOf", "allOf"] {
        if let Some(Value::Array(variants)) = map.get_mut(key) {
            variants.iter_mut().for_each(tighten);
        }
    }
    for key in ["$defs", "definitions"] {
        if let Some(Value::Object(defs)) = map.get_mut(key) {
            defs.values_mut().for_each(tighten);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use schemars::{schema_for, JsonSchema};
    use serde::Deserialize;

    #[derive(Deserialize, JsonSchema)]
    #[allow(dead_code)]
    struct Inner {
        confidence: Option<f64>,
    }

    #[derive(Deserialize, JsonSchema)]
    #[allow(dead_code)]
    struct Outer {
        /// Field docs survive as descriptions.
        idea: String,
        indices: Vec<usize>,
        note: Option<String>,
        inner: Option<Inner>,
    }

    #[test]
    fn test_strict_schema_requires_every_property_and_forbids_extras() {
        let schema = strict_schema(serde_json::to_value(schema_for!(Outer)).unwrap());
        let mut required: Vec<&str> = schema["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        required.sort_unstable();
        assert_eq!(required, ["idea", "indices", "inner", "note"]);
        assert_eq!(schema["additionalProperties"], false);
        assert_eq!(schema["type"], "object");
        assert_eq!(
            schema["properties"]["idea"]["description"],
            "Field docs survive as descriptions."
        );
    }

    #[test]
    fn test_strict_schema_strips_rejected_annotations_everywhere() {
        let schema = strict_schema(serde_json::to_value(schema_for!(Outer)).unwrap());
        let text = serde_json::to_string(&schema).unwrap();
        assert!(!text.contains("\"$schema\""), "{text}");
        assert!(!text.contains("\"title\""), "{text}");
        assert!(!text.contains("\"format\""), "{text}");
        // Array items and optional fields keep their types.
        assert_eq!(schema["properties"]["indices"]["items"]["type"], "integer");
        assert_eq!(
            schema["properties"]["note"]["type"],
            serde_json::json!(["string", "null"])
        );
    }

    #[test]
    fn test_strict_schema_tightens_nested_definitions() {
        let schema = strict_schema(serde_json::to_value(schema_for!(Outer)).unwrap());
        let inner = &schema["$defs"]["Inner"];
        assert_eq!(inner["additionalProperties"], false);
        assert_eq!(inner["required"], serde_json::json!(["confidence"]));
        assert!(inner.get("format").is_none());
    }

    #[test]
    fn test_strict_schema_leaves_property_named_like_keyword() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {"title": {"type": "string"}, "format": {"type": "string"}}
        });
        let strict = strict_schema(schema);
        assert!(strict["properties"].get("title").is_some());
        assert!(strict["properties"].get("format").is_some());
    }
}
