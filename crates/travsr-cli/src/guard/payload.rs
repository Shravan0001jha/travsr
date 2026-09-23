//! The Claude Code `PreToolUse` wire types (#916).
//!
//! Both directions are typed rather than poked at as `serde_json::Value`, so a
//! field the host renames fails to deserialize in one place instead of silently
//! reading as `None` five call sites deep. Every field is optional on the way
//! in: the guard has to answer a payload from a newer host that added fields,
//! and from an older one that has not got them yet, and neither is an error.
//!
//! Contract reference: <https://code.claude.com/docs/en/hooks>, `PreToolUse`.
//! The decision lives under `hookSpecificOutput`, not at the top level. An
//! earlier sketch of this feature emitted a bare `{"permissionDecision": ...}`;
//! Claude Code ignores that shape, so the guard would have been inert in
//! exactly the mode that is supposed to block.

use serde::{Deserialize, Serialize};

/// What the host writes on the guard's stdin.
///
/// `#[serde(default)]` throughout: a missing `session_id` (a very old host, or
/// a hand-driven test) must degrade to "no session release valve", not to a
/// parse failure that fails the whole payload open when it did not need to.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub struct HookInput {
    /// Session identifier. Scopes the strict-mode release valve.
    pub session_id: Option<String>,
    /// The directory the agent is working in. The repo root is resolved from it.
    pub cwd: Option<String>,
    /// `"PreToolUse"` for the event this guard handles. Anything else is passed
    /// through: the hook is only ever registered for `PreToolUse`, so another
    /// value means the settings file was hand-edited and the guard has no
    /// business deciding.
    pub hook_event_name: Option<String>,
    /// `Grep`, `Glob`, `Read`, `Bash`, or anything else the matcher let through.
    pub tool_name: Option<String>,
    /// The tool's own arguments, shape-dependent.
    pub tool_input: Option<ToolInput>,
}

/// The union of the `tool_input` fields this guard reads.
///
/// One struct rather than an enum keyed on `tool_name`, because the host is
/// free to add tools whose input overlaps these names and an unknown-variant
/// error would be a parse failure over a payload we can read perfectly well.
/// Unread fields are dropped.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub struct ToolInput {
    /// `Bash`: the command line.
    pub command: Option<String>,
    /// `Grep`: the regular expression.
    pub pattern: Option<String>,
    /// `Glob`: the glob. (`Grep` also accepts one, to scope the search.)
    pub glob: Option<String>,
    /// `Grep` / `Glob`: the directory to search under.
    pub path: Option<String>,
    /// `Read`: the file to read.
    pub file_path: Option<String>,
    /// `Read`: a partial read starts here.
    pub offset: Option<u64>,
    /// `Read`: a partial read stops after this many lines.
    pub limit: Option<u64>,

    // The Travsr MCP tools' own arguments. The installed hook matches them too,
    // so the guard can see that the agent has been to the graph — which is what
    // releases the strict-mode valve (see `guard::session`). It never decides
    // anything about these calls; it observes and allows.
    /// `get_callers`, `find_references`: the symbol being asked about.
    pub symbol: Option<String>,
    /// `get_context`, `get_graph_json`: the query.
    pub query: Option<String>,
    /// `search_symbol`: the name.
    pub name: Option<String>,
    /// `get_dependencies`, `get_blast_radius`: the file.
    pub file: Option<String>,
}

/// The three decisions the host understands.
///
/// `Ask` is part of the contract and nothing here constructs it, deliberately.
/// The guard's whole argument is that it knows which calls the graph can
/// replace; handing that judgement to a permission prompt would put a decision
/// in front of the user on every `grep` and teach the agent nothing either way.
/// It stays in the enum because [`HookOutput::blocks`] has to classify it
/// correctly if a later mode ever does emit it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Permission {
    Allow,
    #[allow(dead_code)]
    Ask,
    Deny,
}

/// What the guard writes on stdout.
///
/// [`HookOutput::Neutral`] is not a fourth decision, it is the *absence* of one:
/// exit 0 with no JSON, which the host documents as "no decision; normal
/// permission flow applies". That distinction is load-bearing and is the reason
/// this is an enum rather than an `Option<Permission>` field.
///
/// `permissionDecision: "allow"` does not mean "do not block", it means
/// "approve this without asking the user". Emitting it for a `Bash` command the
/// guard has not positively identified would auto-approve whatever that command
/// turns out to be, so the guard emits it only for calls it has recognised as
/// read-only, and passes everything else through untouched. Both outcomes
/// satisfy the fail-open rule — neither blocks — but only one of them spends
/// the user's permission settings to do it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookOutput {
    /// No JSON on stdout: the host applies its normal permission flow.
    Neutral,
    /// An explicit decision, with the reason the agent gets to read.
    Decide {
        permission: Permission,
        reason: String,
        /// Text folded into the agent's context. `permissionDecisionReason` is
        /// surfaced to the agent on a `deny` but is display-only on an `allow`,
        /// so advisory mode — whose entire product is the redirect it teaches —
        /// carries the same text here as well or it teaches nothing.
        context: Option<String>,
    },
}

impl HookOutput {
    /// An explicit `allow` with a redirect the agent can act on.
    pub fn allow(reason: impl Into<String>) -> Self {
        let reason = reason.into();
        HookOutput::Decide {
            permission: Permission::Allow,
            context: Some(reason.clone()),
            reason,
        }
    }

    /// A `deny` naming the Travsr call that replaces the blocked one.
    pub fn deny(reason: impl Into<String>) -> Self {
        HookOutput::Decide {
            permission: Permission::Deny,
            reason: reason.into(),
            context: None,
        }
    }

    /// The bytes to write on stdout. Empty for [`HookOutput::Neutral`].
    pub fn render(&self) -> String {
        match self {
            HookOutput::Neutral => String::new(),
            HookOutput::Decide {
                permission,
                reason,
                context,
            } => {
                let mut specific = serde_json::json!({
                    "hookEventName": "PreToolUse",
                    "permissionDecision": permission,
                    "permissionDecisionReason": reason,
                });
                if let Some(extra) = context {
                    specific["additionalContext"] = serde_json::Value::String(extra.clone());
                }
                // `to_string` on an object built from `json!` cannot fail.
                serde_json::json!({ "hookSpecificOutput": specific }).to_string()
            }
        }
    }

    /// Whether this output blocks the tool call. The property every fail-open
    /// test asserts the negation of.
    ///
    /// Test-only: the guard itself never branches on its own decision, it
    /// renders it. This exists so a test can state the fail-open invariant
    /// once, in the vocabulary of the contract, rather than re-deriving it
    /// from a string comparison at each call site.
    #[cfg(test)]
    pub fn blocks(&self) -> bool {
        matches!(
            self,
            HookOutput::Decide {
                permission: Permission::Deny | Permission::Ask,
                ..
            }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_decision_renders_under_hook_specific_output() {
        let v: serde_json::Value =
            serde_json::from_str(&HookOutput::deny("call get_callers").render()).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PreToolUse");
        assert_eq!(v["hookSpecificOutput"]["permissionDecision"], "deny");
        assert_eq!(
            v["hookSpecificOutput"]["permissionDecisionReason"],
            "call get_callers"
        );
        // A deny's reason already reaches the agent; duplicating it as
        // additionalContext would print it twice.
        assert!(v["hookSpecificOutput"]["additionalContext"].is_null());
    }

    #[test]
    fn an_allow_carries_the_redirect_as_context_too() {
        let v: serde_json::Value =
            serde_json::from_str(&HookOutput::allow("prefer find_references").render()).unwrap();
        assert_eq!(v["hookSpecificOutput"]["permissionDecision"], "allow");
        assert_eq!(
            v["hookSpecificOutput"]["additionalContext"], "prefer find_references",
            "advisory mode teaches through additionalContext; an allow's reason \
             is display-only"
        );
    }

    #[test]
    fn neutral_renders_nothing_at_all() {
        assert_eq!(HookOutput::Neutral.render(), "");
        assert!(!HookOutput::Neutral.blocks());
    }

    #[test]
    fn only_deny_and_ask_block() {
        assert!(HookOutput::deny("x").blocks());
        assert!(!HookOutput::allow("x").blocks());
    }

    #[test]
    fn a_payload_missing_every_optional_field_still_parses() {
        let p: HookInput = serde_json::from_str("{}").unwrap();
        assert!(p.tool_name.is_none());
        assert!(p.tool_input.is_none());
    }

    #[test]
    fn unknown_fields_are_ignored_not_rejected() {
        let p: HookInput = serde_json::from_str(
            r#"{"tool_name":"Grep","tool_input":{"pattern":"foo","some_new_field":1},
                "a_field_from_a_newer_host":true}"#,
        )
        .expect("a newer host's extra fields must not fail the parse");
        assert_eq!(p.tool_name.as_deref(), Some("Grep"));
        assert_eq!(p.tool_input.and_then(|i| i.pattern).as_deref(), Some("foo"));
    }

    #[test]
    fn the_documented_payload_shape_round_trips() {
        // Verbatim from the hook reference, trimmed to the fields we read.
        let p: HookInput = serde_json::from_str(
            r#"{
              "session_id": "abc123",
              "transcript_path": "/home/user/.claude/projects/x/transcript.jsonl",
              "cwd": "/home/user/my-project",
              "permission_mode": "default",
              "hook_event_name": "PreToolUse",
              "tool_name": "Bash",
              "tool_input": { "command": "rg needle" },
              "tool_use_id": "toolu_01ABC123"
            }"#,
        )
        .unwrap();
        assert_eq!(p.session_id.as_deref(), Some("abc123"));
        assert_eq!(p.cwd.as_deref(), Some("/home/user/my-project"));
        assert_eq!(p.hook_event_name.as_deref(), Some("PreToolUse"));
        assert_eq!(p.tool_name.as_deref(), Some("Bash"));
        assert_eq!(
            p.tool_input.and_then(|i| i.command).as_deref(),
            Some("rg needle")
        );
    }
}
