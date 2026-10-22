//! Plugin sources embedded into the binary at build time.

pub struct Asset {
    /// Path relative to the project root.
    pub path: &'static str,
    pub content: &'static str,
}

pub const FILES: &[Asset] = &[
    Asset {
        path: "addons/gdcli/plugin.cfg",
        content: include_str!("../assets/addons/gdcli/plugin.cfg"),
    },
    Asset {
        path: "addons/gdcli/plugin.gd",
        content: include_str!("../assets/addons/gdcli/plugin.gd"),
    },
    Asset {
        path: "addons/gdcli/debug_capture.gd",
        content: include_str!("../assets/addons/gdcli/debug_capture.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/meta.gd",
        content: include_str!("../assets/addons/gdcli/commands/meta.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/editor.gd",
        content: include_str!("../assets/addons/gdcli/commands/editor.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/scene.gd",
        content: include_str!("../assets/addons/gdcli/commands/scene.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/node.gd",
        content: include_str!("../assets/addons/gdcli/commands/node.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/prop.gd",
        content: include_str!("../assets/addons/gdcli/commands/prop.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/signal.gd",
        content: include_str!("../assets/addons/gdcli/commands/signal.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/group.gd",
        content: include_str!("../assets/addons/gdcli/commands/group.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/res.gd",
        content: include_str!("../assets/addons/gdcli/commands/res.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/project.gd",
        content: include_str!("../assets/addons/gdcli/commands/project.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/fs.gd",
        content: include_str!("../assets/addons/gdcli/commands/fs.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/script.gd",
        content: include_str!("../assets/addons/gdcli/commands/script.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/game.gd",
        content: include_str!("../assets/addons/gdcli/commands/game.gd"),
    },
    Asset {
        path: "addons/gdcli/commands/input.gd",
        content: include_str!("../assets/addons/gdcli/commands/input.gd"),
    },
    Asset {
        path: "addons/gdcli/runtime/gdcli_runtime.gd",
        content: include_str!("../assets/addons/gdcli/runtime/gdcli_runtime.gd"),
    },
];

const PLUGIN_CFG: &str = include_str!("../assets/addons/gdcli/plugin.cfg");

/// `version="..."` from the embedded plugin.cfg.
pub fn embedded_version() -> Option<String> {
    plugin_version(PLUGIN_CFG)
}

/// Reads the `version` key from a plugin.cfg.
pub fn plugin_version(cfg: &str) -> Option<String> {
    cfg.lines().find_map(|line| {
        let rest = line.trim().strip_prefix("version")?;
        let rest = rest.trim_start();
        let rest = rest.strip_prefix('=')?.trim();
        Some(rest.trim_matches('"').to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_embedded_plugin_version() {
        let version = embedded_version().expect("plugin.cfg should carry a version");
        assert!(!version.is_empty());
    }

    #[test]
    fn embedded_version_matches_the_crate_version() {
        assert_eq!(
            embedded_version().as_deref(),
            Some(env!("CARGO_PKG_VERSION")),
            "assets/addons/gdcli/plugin.cfg must carry the same version as Cargo.toml"
        );
    }

    #[test]
    fn plugin_sources_do_not_hardcode_a_version() {
        for asset in FILES {
            assert!(
                !asset.content.contains("VERSION := \""),
                "{} hardcodes a version; read it from plugin.cfg instead",
                asset.path
            );
        }
    }

    #[test]
    fn ignores_keys_that_only_start_with_version() {
        assert_eq!(plugin_version("versioned=\"9\"\n"), None);
        assert_eq!(
            plugin_version("  version = \"1.2.3\"\n"),
            Some("1.2.3".into())
        );
    }

    #[test]
    fn embeds_every_plugin_file() {
        let paths: Vec<_> = FILES.iter().map(|asset| asset.path).collect();
        assert!(paths.contains(&"addons/gdcli/plugin.cfg"));
        assert!(paths.contains(&"addons/gdcli/plugin.gd"));
        assert!(paths.contains(&"addons/gdcli/debug_capture.gd"));
        assert!(paths.contains(&"addons/gdcli/commands/game.gd"));
        assert!(paths.contains(&"addons/gdcli/commands/input.gd"));
        assert!(paths.contains(&"addons/gdcli/commands/node.gd"));
        assert!(paths.contains(&"addons/gdcli/runtime/gdcli_runtime.gd"));
        for path in [
            "addons/gdcli/commands/signal.gd",
            "addons/gdcli/commands/group.gd",
            "addons/gdcli/commands/res.gd",
            "addons/gdcli/commands/project.gd",
            "addons/gdcli/commands/fs.gd",
            "addons/gdcli/commands/script.gd",
        ] {
            assert!(paths.contains(&path), "missing embedded {path}");
        }
    }
}
