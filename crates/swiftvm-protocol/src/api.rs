//! API v1, as `swiftvm serve` speaks it, and the turning of the app's own messages into it.
//!
//! The service passes the requests it doesn't answer itself on to the app, and its answers back. It does
//! that on JSON values rather than on the types in `wire`, so that what a newer app or client adds goes
//! through a service that doesn't know of it yet.

use serde_json::{Map, Value};

use crate::wire::{ErrorCode, SwiftDate, Timestamp};

/// The version of the API this crate speaks.
pub const PROTOCOL: u32 = 1;

/// The versions of the API the service speaks, oldest first.
pub const PROTOCOLS: [u32; 1] = [PROTOCOL];

/// What the platform the service runs on is called in `hello`.
pub fn platform() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "linux"
    }
}

/// A request in API v1 made fit for the app: without its `id`, which the app doesn't take, and with each
/// click target as Swift codes it (`{"number":{"_0":12}}`).
pub fn request_for_app(mut request: Value) -> Value {
    if let Some(fields) = request.as_object_mut() {
        fields.remove("id");
        if let Some(steps) = fields.get_mut("control").and_then(|call| call.get_mut("steps")).and_then(Value::as_array_mut) {
            for step in steps.iter_mut().filter_map(Value::as_object_mut) {
                for key in ["target", "to"] {
                    if let Some(target) = step.get_mut(key) {
                        swift_target(target);
                    }
                }
            }
        }
    }
    request
}

/// `{"number":12}` as `{"number":{"_0":12}}`. A place, `{"point":{"x":1,"y":2}}`, is the same in both.
fn swift_target(target: &mut Value) {
    let Some(fields) = target.as_object_mut() else { return };
    for kind in ["number", "text", "id"] {
        if let Some(value) = fields.get_mut(kind)
            && !value.is_object()
        {
            let mut wrapped = Map::new();
            wrapped.insert("_0".into(), value.take());
            *value = Value::Object(wrapped);
        }
    }
}

/// The app's answer to a request made fit for the client: with the request's `id`, the failure as an
/// object with its code, and dates in RFC 3339.
pub fn answer_from_app(mut answer: Value, id: Option<u64>) -> Value {
    let Some(fields) = answer.as_object_mut() else { return answer };
    let code = fields.remove("code").and_then(|code| code.as_str().map(str::to_string));
    if let Some(message) = fields.get("error").and_then(Value::as_str).map(str::to_string) {
        let mut error = Map::new();
        error.insert("code".into(), Value::String(code.unwrap_or_else(|| ErrorCode::Failed.name().into())));
        error.insert("message".into(), Value::String(message));
        fields.insert("error".into(), Value::Object(error));
    } else if fields.get("ok") == Some(&Value::Bool(false)) {
        // A failure without words still says what kind it was.
        let mut error = Map::new();
        error.insert("code".into(), Value::String(code.unwrap_or_else(|| ErrorCode::Failed.name().into())));
        error.insert("message".into(), Value::String("The command failed.".into()));
        fields.insert("error".into(), Value::Object(error));
    }
    for list in ["snapshots", "templates"] {
        for item in fields.get_mut(list).and_then(Value::as_array_mut).into_iter().flatten() {
            if let Some(created) = item.get_mut("createdAt")
                && let Some(seconds) = created.as_f64()
            {
                *created = Value::String(Timestamp::from(SwiftDate(seconds)).rfc3339());
            }
        }
    }
    match id {
        Some(id) => fields.insert("id".into(), Value::from(id)),
        None => fields.remove("id"),
    };
    answer
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_failure_from_the_app_keeps_its_code_and_words() {
        let answer =
            answer_from_app(json!({"ok": false, "error": "“desk” isn't running.", "code": "wrong-state", "machines": []}), Some(4));
        assert_eq!(
            answer,
            json!({"id": 4, "ok": false, "error": {"code": "wrong-state", "message": "“desk” isn't running."}, "machines": []})
        );
        // An app from before codes.
        let answer = answer_from_app(json!({"ok": false, "error": "No.", "machines": []}), Some(5));
        assert_eq!(answer["error"], json!({"code": "failed", "message": "No."}));
    }

    #[test]
    fn a_moment_is_written_in_rfc_3339() {
        assert_eq!(Timestamp::from(SwiftDate(785_000_000.5)).rfc3339(), "2025-11-16T15:33:20.5Z");
        assert_eq!(Timestamp::parse("2025-11-16T15:33:20.5Z"), Some(Timestamp::from(SwiftDate(785_000_000.5))));
        assert_eq!(Timestamp::parse("2025-11-16T16:33:20.5+01:00"), Some(Timestamp::from(SwiftDate(785_000_000.5))));
    }
}
