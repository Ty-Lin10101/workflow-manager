use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Workflow {
    id: String,
    name: String,
    todos: Vec<TodoItem>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct TodoItem {
    id: String,
    description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    due: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration_minutes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    notes: Option<String>,
    completed: bool,
}

fn database_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("workflows.sqlite3"))
}

fn open_database(app: &AppHandle) -> Result<Connection, String> {
    let connection = Connection::open(database_path(app)?).map_err(|e| e.to_string())?;
    connection
        .execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS workflows (
                 id TEXT PRIMARY KEY NOT NULL,
                 name TEXT NOT NULL,
                 position INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS todos (
                 id TEXT PRIMARY KEY NOT NULL,
                 workflow_id TEXT NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
                 description TEXT NOT NULL,
                 due TEXT,
                 duration_minutes INTEGER,
                 notes TEXT,
                 completed INTEGER NOT NULL,
                 position INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS todos_workflow_position
                 ON todos(workflow_id, position);
             CREATE TABLE IF NOT EXISTS app_metadata (
                 key TEXT PRIMARY KEY NOT NULL,
                 value TEXT NOT NULL
             );",
        )
        .map_err(|e| e.to_string())?;
    Ok(connection)
}

fn replace_workflows(connection: &Connection, workflows: &[Workflow]) -> Result<(), String> {
    let transaction = connection
        .unchecked_transaction()
        .map_err(|e| e.to_string())?;
    transaction
        .execute("DELETE FROM workflows", [])
        .map_err(|e| e.to_string())?;

    for (workflow_position, workflow) in workflows.iter().enumerate() {
        transaction
            .execute(
                "INSERT INTO workflows (id, name, position) VALUES (?1, ?2, ?3)",
                params![workflow.id, workflow.name, workflow_position as i64],
            )
            .map_err(|e| e.to_string())?;

        for (todo_position, todo) in workflow.todos.iter().enumerate() {
            transaction
                .execute(
                    "INSERT INTO todos
                     (id, workflow_id, description, due, duration_minutes, notes, completed, position)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    params![
                        todo.id,
                        workflow.id,
                        todo.description,
                        todo.due,
                        todo.duration_minutes,
                        todo.notes,
                        todo.completed,
                        todo_position as i64
                    ],
                )
                .map_err(|e| e.to_string())?;
        }
    }

    transaction
        .execute(
            "INSERT INTO app_metadata (key, value) VALUES ('workflows_initialized', 'true')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )
        .map_err(|e| e.to_string())?;
    transaction.commit().map_err(|e| e.to_string())
}

fn read_workflows(connection: &Connection) -> Result<Vec<Workflow>, String> {
    let mut workflow_statement = connection
        .prepare("SELECT id, name FROM workflows ORDER BY position, id")
        .map_err(|e| e.to_string())?;
    let workflow_rows = workflow_statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|e| e.to_string())?;
    let mut workflows = Vec::new();

    for row in workflow_rows {
        let (id, name) = row.map_err(|e| e.to_string())?;
        let mut todo_statement = connection
            .prepare(
                "SELECT id, description, due, duration_minutes, notes, completed
                 FROM todos WHERE workflow_id = ?1 ORDER BY position, id",
            )
            .map_err(|e| e.to_string())?;
        let todo_rows = todo_statement
            .query_map([&id], |row| {
                Ok(TodoItem {
                    id: row.get(0)?,
                    description: row.get(1)?,
                    due: row.get(2)?,
                    duration_minutes: row.get(3)?,
                    notes: row.get(4)?,
                    completed: row.get(5)?,
                })
            })
            .map_err(|e| e.to_string())?;
        let todos = todo_rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        workflows.push(Workflow { id, name, todos });
    }

    Ok(workflows)
}

fn import_legacy_workflows(connection: &Connection, app: &AppHandle) -> Result<(), String> {
    let imported: Option<String> = connection
        .query_row(
            "SELECT value FROM app_metadata WHERE key = 'legacy_workflows_imported'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;

    if imported.is_some() {
        return Ok(());
    }

    let legacy_path = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("workflows.json");
    if legacy_path.exists() {
        let raw = fs::read_to_string(legacy_path).map_err(|e| e.to_string())?;
        let workflows: Vec<Workflow> = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        replace_workflows(connection, &workflows)?;
    }

    connection
        .execute(
            "INSERT INTO app_metadata (key, value) VALUES ('legacy_workflows_imported', 'true')",
            [],
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn load_workflows(app: AppHandle) -> Result<Option<String>, String> {
    let connection = open_database(&app)?;
    import_legacy_workflows(&connection, &app)?;
    let initialized: Option<String> = connection
        .query_row(
            "SELECT value FROM app_metadata WHERE key = 'workflows_initialized'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    if initialized.is_none() {
        return Ok(None);
    }

    let workflows = read_workflows(&connection)?;
    serde_json::to_string(&workflows)
        .map(Some)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn save_workflows(app: AppHandle, data: String) -> Result<(), String> {
    let workflows: Vec<Workflow> = serde_json::from_str(&data).map_err(|e| e.to_string())?;
    let connection = open_database(&app)?;
    replace_workflows(&connection, &workflows)
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

            app.handle()
                .plugin(tauri_plugin_updater::Builder::new().build())?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![load_workflows, save_workflows])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
