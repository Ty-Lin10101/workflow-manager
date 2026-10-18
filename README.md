# Workflow Manager

Workflow Manager is a small desktop task manager organized around workflows. A workflow contains an ordered list of tasks, and each task can have a description, due date and time, estimated duration, notes, and a completion state.

## Architecture

The app has a shared React and TypeScript frontend, built by Vite, with desktop host options for Electron and Tauri. The frontend can also run in a browser. The repository includes a local SQLite backend for Tauri and a Supabase/PostgreSQL backend foundation for future shared workflows.

```text
React UI (src/)
    ├── Electron preload bridge → Electron main process → legacy JSON persistence (not in current backend scope)
    ├── Tauri invoke commands → Rust host → local SQLite + outbox
    └── Supabase Auth + PostgreSQL (backend foundation; not connected to the app)
```

**Supabase sync is not implemented in the app yet.** The database schema and
sync RPCs are backend groundwork only; the browser, Electron, and Tauri apps do
not currently use them. Workflows remain local to each browser or desktop
installation, and users cannot share workflow data through the app.

### Frontend

- `src/main.tsx` creates the React root and loads the shared stylesheet.
- `src/App.tsx` owns the workflow collection and selected workflow, coordinates create/update/delete/reorder actions, and reads and writes persisted data.
- `src/models.ts` defines the `Workflow` and `TodoItem` data shapes and shared ID helpers.
- `src/components/WorkflowList.tsx` presents and sorts workflows; `TodoList.tsx` presents, filters, sorts, edits, reorders, and removes tasks.
- `NewWorkflowForm.tsx` and `NewTodoForm.tsx` keep form input and validation local to their respective forms.
- `src/styles.css` contains the shared application styling.

The UI is split by responsibility while the app-level state stays in one place. This keeps updates to the selected workflow and persistence straightforward without introducing a separate state-management library for a small app.

### Desktop hosts and persistence

The renderer persists through its host `loadWorkflows` / `saveWorkflows`
methods when available, then falls back to browser `localStorage`.

- **Electron:** `electron/main.js` owns filesystem access and IPC. `electron/preload.js` exposes the workflow snapshot methods. Workflows are saved as JSON in Electron's per-user application data directory.
- **Tauri:** `src-tauri/src/lib.rs` stores workflows and tasks in SQLite under the platform-specific application data directory. Workflow and task ordering, due dates, durations, notes, and completion state are persisted transactionally. On first run it imports an existing `workflows.json` file from the Tauri application data directory; it does not import Electron's data file.
- **Browser/fallback:** The current renderer stores serialized workflows in `localStorage` under `todo_desktop_workflows_v1`; it does not yet provide SQL-backed offline sync in a browser.

Electron and Tauri keep workflows in separate local stores. Changes made in one
app do not appear in the other, even when both are installed on the same
computer; there is no cross-host synchronization.

Native hosts keep database and file operations outside the React UI and expose
only application-level commands. Tauri uses SQLite for local persistence;
server synchronization and an outbox are not yet connected to the desktop UI.

### Shared workflow backend (not yet used by the app)

Supabase provides hosted PostgreSQL and user authentication. The database
migration under `supabase/migrations/` creates normalized workflow, task,
membership, and sync-event tables; row-level security limits reads by
membership, and server-side RPCs validate writes and roles. Indexed SQL RPCs
provide bounded keyset pages rather than fetching and sorting an entire task
list on each request.

The server RPCs support clients pushing batches of outbox operations with
optimistic versions, then pulling bounded change events by cursor. A conflict
returns the server version for explicit resolution. If event history has been
pruned, the server requires a fresh membership-visible snapshot before sync
resumes. The desktop UI does not yet call these RPCs; local SQLite changes are
not synchronized with Supabase. The global transactional cursor favors
reliable ordered sync and simple recovery; a much higher write rate may call
for per-workflow cursor streams.

See [supabase/README.md](./supabase/README.md) for setup, RPC payloads, cursor
handling, role rules, and deployment guidance. Desktop clients must use only a
Supabase publishable/anon key with user authentication; the service-role key is
reserved for trusted maintenance and must never be bundled with the app.

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

To let other people on your local network open your running development app,
start the server on your computer with:

```bash
npm run dev -- --host 0.0.0.0
```

Share the **Network** URL printed by Vite with people on the same network. They
can open it in a browser without installing the app. The server is only
reachable on your local network (and may require allowing port `5173` through
your firewall); this does not publish the app to the internet. Workflows stay
in each visitor's browser storage, so users do not share data.

Run the Electron development command:

```bash
npm run start:electron
```

Build the Windows Electron installer:

```bash
npm run build:electron
```

The installer is written to `electron-dist/`. Electron stores its workflows
separately from the Tauri app.

Run the Tauri development app (requires the Rust toolchain and platform prerequisites for Tauri):

```bash
npm run tauri:dev
```

## Build commands

```bash
npm run build       # Build the frontend into dist/
npm run tauri:build # Build the Tauri desktop app
npm run build:electron # Build the Electron Windows installer
```

`npm run preview` serves the production frontend locally. The Electron runtime
is launched through the `main` entry in `package.json` (`electron/main.js`).
