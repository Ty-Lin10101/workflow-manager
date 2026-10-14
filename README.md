# Todo Desktop

Todo Desktop is a small desktop task manager organized around workflows. A workflow contains an ordered list of tasks, and each task can have a description, due date and time, estimated duration, notes, and a completion state.

## Architecture

The app has a shared React and TypeScript frontend, built by Vite, with desktop host options for Electron and Tauri. The frontend can also run in a browser. The backend foundation adds local SQL storage for offline use and a Supabase/PostgreSQL service for shared workflows.

```text
React UI (src/)
    ├── Electron preload bridge → Electron main process → local SQLite + outbox
    ├── Tauri invoke commands → Rust host → local SQLite + outbox
    └── Supabase Auth + PostgreSQL → shared workflows + sync event feed
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

The existing renderer currently persists through its host `loadWorkflows` /
`saveWorkflows` methods when available, then falls back to browser `localStorage`.
The native SQLite/outbox APIs are backend foundations; wiring the UI and sync
status to those APIs is a separate client-integration step.

- **Electron:** `electron/main.js` owns filesystem access and IPC. `electron/preload.js` exposes a narrow API to the renderer. The backend stores normalized local data and pending mutations in SQLite.
- **Tauri:** `src-tauri/src/lib.rs` owns native commands and local SQL access. It stores workflows, tasks, and the durable sync outbox in SQLite.
- **Browser/fallback:** The current renderer stores serialized workflows in `localStorage` under `todo_desktop_workflows_v1`; it does not yet provide SQL-backed offline sync in a browser.

Native hosts keep database and file operations outside the React UI and expose
only application-level commands. SQLite supports indexed queries and
transactional outbox writes without requiring a network connection. The
outbox keeps an operation ID and expected server version so retries are
idempotent and concurrent edits can be reported as conflicts instead of
silently overwriting data.

### Shared workflows and server sync

Supabase provides hosted PostgreSQL and user authentication. The database
migration under `supabase/migrations/` creates normalized workflow, task,
membership, and sync-event tables; row-level security limits reads by
membership, and server-side RPCs validate writes and roles. Indexed SQL RPCs
provide bounded keyset pages rather than fetching and sorting an entire task
list on each request.

Clients push batches of outbox operations with optimistic versions, then pull
bounded change events by cursor. A conflict returns the server version for
explicit resolution. If event history has been pruned, the server requires a
fresh membership-visible snapshot before sync resumes. Offline edits remain
in the local outbox until the server acknowledges or the user resolves them.
The global transactional cursor favors reliable ordered sync and simple
recovery; a much higher write rate may call for per-workflow cursor streams.

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
