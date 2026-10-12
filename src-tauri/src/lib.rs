use std::fs;

#[tauri::command]
fn load_workflows() -> Result<Option<String>, String> {
  let dir = tauri::api::path::app_dir().ok_or_else(|| "could not determine app dir".to_string())?;
  let p = dir.join("workflows.json");
  if !p.exists() {
    return Ok(None);
  }
  fs::read_to_string(p).map(Some).map_err(|e| e.to_string())
}

#[tauri::command]
fn save_workflows(data: String) -> Result<bool, String> {
  let dir = tauri::api::path::app_dir().ok_or_else(|| "could not determine app dir".to_string())?;
  fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
  let p = dir.join("workflows.json");
  fs::write(p, data).map(|_| true).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  tauri::Builder::default()
    .setup(|app| {
      if cfg!(debug_assertions) {
        app.handle().plugin(
          tauri_plugin_log::Builder::default()
            .level(log::LevelFilter::Info)
            .build(),
        )?;
      }

      app.handle().plugin(tauri_plugin_updater::Builder::new().build())?;
      Ok(())
    })
    .invoke_handler(tauri::generate_handler![load_workflows, save_workflows])
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
