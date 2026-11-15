use crate::error::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub vault_path: String,
    pub side: String,
    pub panel_width: f64,
    pub edge_activation: bool,
    pub activation_delay_ms: u64,
    pub hide_delay_ms: u64,
    pub toggle_shortcut: String,
    pub theme: String,
    pub font_size: f64,
    pub show_hidden_files: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            vault_path: String::new(),
            side: "right".into(),
            panel_width: 460.0,
            edge_activation: true,
            activation_delay_ms: 300,
            hide_delay_ms: 300,
            toggle_shortcut: "CmdOrCtrl+Shift+Space".into(),
            theme: "system".into(),
            font_size: 15.0,
            show_hidden_files: false,
        }
    }
}

impl Settings {
    pub fn load(file: &Path, default_vault: PathBuf) -> Settings {
        let mut s: Settings = std::fs::read(file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        if s.vault_path.is_empty() {
            s.vault_path = default_vault.to_string_lossy().into_owned();
        }
        s.sanitize();
        s
    }

    pub fn sanitize(&mut self) {
        if self.side != "left" {
            self.side = "right".into();
        }
        self.panel_width = self.panel_width.clamp(320.0, 900.0);
        self.font_size = self.font_size.clamp(11.0, 24.0);
        self.activation_delay_ms = self.activation_delay_ms.min(5000);
        self.hide_delay_ms = self.hide_delay_ms.min(10000);
    }

    pub fn save(&self, file: &Path) -> Result<()> {
        crate::vault::atomic_write(file, &serde_json::to_vec_pretty(self)?)
    }
}
