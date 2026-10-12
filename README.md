# Todo Desktop

A small desktop todo app (React + TypeScript) supporting multiple workflows.

Features:
- Workflows contain multiple todo items
- Todo item: description, due date/time, duration (minutes), notes, completed flag
- Clear all finished tasks in a workflow
- Multiple workflows supported

Quick start (development):

1. Install dependencies (Node + npm):

```bash
npm install
```

2. Run Vite dev server and Electron together:

```bash
npm run start:electron
```

This runs a Vite dev server and opens Electron pointed at the dev server.

Tauri (optional):

- Tauri requires Rust and the Tauri CLI. See https://tauri.app for setup.
- Once Rust + tauri are installed:

```bash
npm install
npm run tauri:dev
```

Notes:
- The current implementation uses `localStorage` in the renderer for persistence so it works in both Electron and Tauri dev.
- The Electron `preload.ts` and Tauri Rust files are stubs for adding native filesystem persistence or IPC later.

If you want, I can add file-based persistence for Electron (saving workflows to a JSON file) or wire Tauri file APIs next.
