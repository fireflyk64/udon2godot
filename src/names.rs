//! Identifier mangling: C# names that collide with GDScript keywords or with members of the
//! Godot classes a converted script extends (Object / Node / Node3D / UdonBehaviour) get a
//! trailing underscore.

const GD_KEYWORDS: &[&str] = &[
    "if", "elif", "else", "for", "while", "match", "when", "break", "continue", "pass", "return", "class", "class_name",
    "extends", "is", "in", "as", "self", "super", "signal", "func", "static", "const", "enum", "var", "breakpoint",
    "preload", "await", "yield", "assert", "void", "PI", "TAU", "INF", "NAN", "and", "or", "not", "true", "false",
    "null", "trait", "namespace", "struct", "abstract", "print", "str", "range", "len", "load", "typeof", "Node",
    "Object", "Variant", "Array", "Dictionary", "String", "Vector3", "Vector2", "Color", "Quaternion", "Transform3D",
    "Basis", "Callable", "Signal", "int", "float", "bool", "Udon", "U", "value", "setget", "onready", "tool", "export",
    "remote", "sync", "master", "puppet", "slave", "do", "case", "switch", "default", "new",
];

/// Members of Object / Node / Node3D (Godot 4) and of the UdonBehaviour runtime base that
/// a script member must not shadow.
const GD_BASE_MEMBERS: &[&str] = &[
    // Object
    "get", "set", "call", "callv", "call_deferred", "connect", "disconnect", "emit_signal", "free", "get_class",
    "is_class", "get_script", "set_script", "has_method", "has_signal", "notification", "to_string", "tr",
    "get_instance_id", "set_meta", "get_meta", "has_meta", "remove_meta", "get_meta_list", "get_method_list",
    "get_property_list", "get_signal_list", "is_blocking_signals", "set_block_signals", "is_queued_for_deletion",
    "property_get_revert", "property_can_revert", "get_incoming_connections", "get_signal_connection_list",
    "add_user_signal", "has_user_signal", "set_deferred", "set_indexed", "get_indexed", "can_translate_messages",
    "set_message_translation", "cancel_free", "notify_property_list_changed",
    // Node
    "name", "owner", "unique_name_in_owner", "scene_file_path", "process_mode", "process_priority",
    "process_physics_priority", "process_thread_group", "multiplayer", "editor_description", "auto_translate_mode",
    "physics_interpolation_mode", "add_child", "remove_child", "get_child", "get_child_count", "get_children",
    "get_parent", "get_node", "get_node_or_null", "has_node", "find_child", "find_children", "find_parent",
    "get_path", "get_path_to", "get_tree", "get_viewport", "get_window", "is_inside_tree", "is_ancestor_of",
    "get_index", "print_tree", "queue_free", "reparent", "replace_by", "set_process", "set_physics_process",
    "set_process_input", "set_process_unhandled_input", "is_processing", "is_physics_processing", "propagate_call",
    "propagate_notification", "add_to_group", "remove_from_group", "is_in_group", "get_groups", "duplicate",
    "move_child", "request_ready", "rpc", "rpc_config", "rpc_id", "set_multiplayer_authority",
    "get_multiplayer_authority", "is_multiplayer_authority", "get_process_delta_time",
    "get_physics_process_delta_time", "create_tween", "get_last_exclusive_window", "set_display_folded",
    "is_displayed_folded", "set_editable_instance", "is_editable_instance", "get_scene_instance_load_placeholder",
    "set_scene_instance_load_placeholder", "update_configuration_warnings", "ready", "renamed", "tree_entered",
    "tree_exited", "tree_exiting", "child_entered_tree", "child_exiting_tree", "child_order_changed",
    "replacing_by", "editor_state_changed", "get_orphan_node_ids", "atr", "atr_n", "is_node_ready",
    "set_thread_safe", "set_process_thread_group", "get_process_thread_group", "is_part_of_edited_scene",
    "set_translation_domain_inherited",
    // Node3D
    "position", "rotation", "rotation_degrees", "rotation_order", "rotation_edit_mode", "quaternion", "basis", "scale",
    "transform", "global_transform", "global_position", "global_basis", "global_rotation", "global_rotation_degrees",
    "visible", "visibility_parent", "top_level", "look_at", "look_at_from_position", "rotate", "rotate_x", "rotate_y",
    "rotate_z", "rotate_object_local", "global_rotate", "global_scale", "global_translate", "translate",
    "translate_object_local", "scale_object_local", "orthonormalize", "set_identity", "to_global", "to_local",
    "show", "hide", "is_visible_in_tree", "get_world_3d", "get_parent_node_3d", "set_ignore_transform_notification",
    "set_as_top_level", "is_set_as_top_level", "set_disable_scale", "is_scale_disabled", "get_global_transform_interpolated",
    "force_update_transform", "set_notify_local_transform", "is_local_transform_notification_enabled",
    "set_notify_transform", "is_transform_notification_enabled", "update_gizmos", "add_gizmo", "get_gizmos",
    "clear_gizmos", "set_subgizmo_selection", "clear_subgizmo_selection", "is_visible", "visibility_changed",
    "set_visibility_parent", "get_visibility_parent",
    // Runtime base (UdonBehaviour.gd) — internal members
    "_udon_ready", "_udon_dispatch", "_udon_started", "_udon_timers", "_udon_synced", "_udon_sync_mode",
    "_udon_class", "_udon_owner", "udon_class", "udon_class_chain", "udon_synced_vars", "udon_sync_mode",
    "udon_field_callbacks", "_ready", "_process", "_physics_process", "_enter_tree", "_exit_tree", "_init",
    "_notification", "_input", "_unhandled_input", "_get", "_set", "_get_property_list", "_to_string",
];

/// Mangle a C# member/local/parameter name into a safe GDScript identifier.
pub fn mangle(name: &str) -> String {
    if GD_KEYWORDS.contains(&name) || GD_BASE_MEMBERS.contains(&name) {
        return format!("{}_", name);
    }
    ascii_identifier(name)
}

/// GDScript accepts Unicode identifiers but SafeGDScript's lexer and the sandbox tooling are
/// safest with ASCII; C# identifiers with non-ASCII letters (Greek maths names are common in Udon
/// physics code) are transliterated: `φ` → `phi`, anything else → `_uXXXX`.
pub fn ascii_identifier(name: &str) -> String {
    if name.is_ascii() {
        return name.to_string();
    }
    let mut out = String::with_capacity(name.len() + 8);
    for c in name.chars() {
        if c.is_ascii() {
            out.push(c);
            continue;
        }
        match greek_name(c) {
            Some(g) => out.push_str(g),
            None => out.push_str(&format!("_u{:04x}", c as u32)),
        }
    }
    out
}

fn greek_name(c: char) -> Option<&'static str> {
    Some(match c {
        'α' => "alpha", 'β' => "beta", 'γ' => "gamma", 'δ' => "delta", 'ε' => "epsilon", 'ζ' => "zeta",
        'η' => "eta", 'θ' => "theta", 'ι' => "iota", 'κ' => "kappa", 'λ' => "lambda", 'μ' => "mu",
        'ν' => "nu", 'ξ' => "xi", 'ο' => "omicron", 'π' => "pi", 'ρ' => "rho", 'σ' => "sigma", 'ς' => "sigma",
        'τ' => "tau", 'υ' => "upsilon", 'φ' => "phi", 'χ' => "chi", 'ψ' => "psi", 'ω' => "omega",
        'Α' => "Alpha", 'Β' => "Beta", 'Γ' => "Gamma", 'Δ' => "Delta", 'Ε' => "Epsilon", 'Ζ' => "Zeta",
        'Η' => "Eta", 'Θ' => "Theta", 'Ι' => "Iota", 'Κ' => "Kappa", 'Λ' => "Lambda", 'Μ' => "Mu",
        'Ν' => "Nu", 'Ξ' => "Xi", 'Ο' => "Omicron", 'Π' => "Pi", 'Ρ' => "Rho", 'Σ' => "Sigma",
        'Τ' => "Tau", 'Υ' => "Upsilon", 'Φ' => "Phi", 'Χ' => "Chi", 'Ψ' => "Psi", 'Ω' => "Omega",
        'ϕ' => "phi", 'ϑ' => "theta", 'ϵ' => "epsilon",
        _ => return None,
    })
}

/// Mangle a local variable or parameter name (only keywords need care; locals may shadow members).
pub fn mangle_local(name: &str) -> String {
    if GD_KEYWORDS.contains(&name) {
        return format!("{}_", name);
    }
    // Locals named like a Node property would shadow it — that's legal in GDScript, but
    // `value` inside a setter is special, and `self`-like names are confusing. Keep the same rule.
    if GD_BASE_MEMBERS.contains(&name) {
        return format!("{}_", name);
    }
    ascii_identifier(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mangles() {
        assert_eq!(mangle("position"), "position_");
        assert_eq!(mangle("match"), "match_");
        assert_eq!(mangle("speed"), "speed");
        assert_eq!(mangle("Start"), "Start");
        assert_eq!(mangle("φ"), "phi");
        assert_eq!(mangle_local("Δθ"), "Deltatheta");
        assert_eq!(mangle("x€"), "x_u20ac");
    }
}
