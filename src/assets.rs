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
        assert!(paths.contains(&"addons/gdcli/commands/node.gd"));
    }
}
