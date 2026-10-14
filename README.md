# Todo Desktop

Todo Desktop is a small desktop task manager organized around workflows. A workflow contains an ordered list of tasks, and each task can have a description, due date and time, estimated duration, notes, and a completion state.

## Architecture

The app has a shared React and TypeScript frontend, built by Vite, with desktop host options for Electron and Tauri. The frontend can also run in a browser.

```text
React UI (src/)
    ├── Electron preload bridge → Electron main process → workflows.json
    ├── Tauri invoke commands → Rust host → workflows.json
    └── Browser/no native host → localStorage
```

### Frontend

- `src/main.tsx` creates the React root and loads the shared stylesheet.
- `src/App.tsx` owns the workflow collection and selected workflow, coordinates create/update/delete/reorder actions, and reads and writes persisted data.
- `src/models.ts` defines the `Workflow` and `TodoItem` data shapes and shared ID helpers.
- `src/components/WorkflowList.tsx` presents and sorts workflows; `TodoList.tsx` presents, filters, sorts, edits, reorders, and removes tasks.
- `NewWorkflowForm.tsx` and `NewTodoForm.tsx` keep form input and validation local to their respective forms.
- `src/styles.css` contains the shared application styling.

The UI is split by responsibility while the app-level state stays in one place. This keeps updates to the selected workflow and persistence straightforward without introducing a separate state-management library for a small app.

### Desktop hosts and persistence

`App.tsx` uses the host API when one is available and falls back to browser `localStorage`:

- **Electron:** `electron/main.js` creates the window and handles file access through IPC. `electron/preload.js` exposes the limited `loadWorkflows` and `saveWorkflows` methods to the renderer. Workflow data is stored as `workflows.json` under Electron's user-data directory.
- **Tauri:** `src-tauri/src/lib.rs` registers `load_workflows` and `save_workflows` commands. The React frontend calls these with Tauri's `invoke` API, and the Rust host reads and writes `workflows.json` in the app directory.
- **Browser/fallback:** The frontend stores serialized workflows in `localStorage` under `todo_desktop_workflows_v1`.

Native hosts keep filesystem operations outside the React UI and expose only the operations the frontend needs. JSON storage keeps the persistence layer small and easy to inspect for this single-user app; a database or remote service would add complexity without a current need for multi-user access or server-side queries.

### Desktop framework choices

The frontend is shared between Electron and Tauri, so the task UI and its behavior do not need separate implementations for each desktop runtime. Electron provides a JavaScript-based desktop host, while Tauri provides a Rust host; either can load the Vite-built frontend. Keeping the host integrations behind small bridges also lets the frontend continue to run in a browser.

## Development

Install dependencies with Node.js and npm:

```bash
npm install
```

Run the browser development server:

```bash
npm run dev
```

Run the Electron development command:

```bash
npm run start:electron
```

Run the Tauri development app (requires the Rust toolchain and platform prerequisites for Tauri):

```bash
npm run tauri:dev
```

## Build commands

```bash
npm run build       # Build the frontend into dist/
npm run tauri:build # Build the Tauri desktop app
```

`npm run preview` serves the production frontend locally. The Electron runtime is launched through the `main` entry in `package.json` (`electron/main.js`).
