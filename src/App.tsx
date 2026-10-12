import React, { useEffect, useState } from 'react'
import { Workflow, ensureUniqueTaskIds } from './models'
import WorkflowList from './components/WorkflowList'
import TodoList from './components/TodoList'
import NewWorkflowForm from './components/NewWorkflowForm'

declare module '@tauri-apps/api/core' {
  export function invoke<T = unknown>(cmd: string, args?: Record<string, unknown>): Promise<T>
}

const STORAGE_KEY = 'todo_desktop_workflows_v1'

async function tryLoadFromTauri(): Promise<string | null> {
  try {
    // dynamic import so it doesn't break web builds
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { invoke } = await import('@tauri-apps/api/core')
    const res = await invoke('load_workflows')
    return typeof res === 'string' ? res : null
  } catch {
    return null
  }
}

export default function App() {
  const [workflows, setWorkflows] = useState<Workflow[]>(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY)
      if (!raw) return []
      return ensureUniqueTaskIds(JSON.parse(raw) as Workflow[])
    } catch {
      return []
    }
  })
  const [activeId, setActiveId] = useState<string | null>(workflows[0]?.id ?? null)

  // load from native hosts (Electron or Tauri) on mount if available
  useEffect(() => {
    ;(async () => {
      try {
        // Electron
        // @ts-ignore
        if (window?.electron?.loadWorkflows) {
          // @ts-ignore
          const raw = await window.electron.loadWorkflows()
          if (raw) {
            const parsed = ensureUniqueTaskIds(JSON.parse(raw) as Workflow[])
            setWorkflows(parsed)
            return
          }
        }

        // Tauri
        const tauriRaw = await tryLoadFromTauri()
        if (tauriRaw) {
          setWorkflows(ensureUniqueTaskIds(JSON.parse(tauriRaw) as Workflow[]))
          return
        }
      } catch {
        // ignore
      }
    })()
  }, [])

  // persist to native hosts or localStorage
  useEffect(() => {
    ;(async () => {
      const payload = JSON.stringify(workflows)
      try {
        // @ts-ignore
        if (window?.electron?.saveWorkflows) {
          // @ts-ignore
          await window.electron.saveWorkflows(payload)
          return
        }
        try {
          // eslint-disable-next-line @typescript-eslint/no-var-requires
          const { invoke } = await import('@tauri-apps/api/core')
          await invoke('save_workflows', { data: payload })
          return
        } catch {}
      } catch {}

      // fallback to localStorage
      try {
        localStorage.setItem(STORAGE_KEY, payload)
      } catch {}
    })()
  }, [workflows])

  useEffect(() => {
    if (!activeId && workflows.length) setActiveId(workflows[0].id)
  }, [workflows, activeId])

  const addWorkflow = (wf: Workflow) => {
    setWorkflows((s: Workflow[]) => [...s, wf])
    setActiveId(wf.id)
  }

  const updateWorkflow = (id: string, updater: (w: Workflow) => Workflow) => {
    setWorkflows((s: Workflow[]) => s.map((w: Workflow) => (w.id === id ? updater(w) : w)))
  }

  const removeCompletedFromWorkflow = (id: string) => {
    updateWorkflow(id, (w: Workflow) => ({ ...w, todos: w.todos.filter((t) => !t.completed) }))
  }

  const deleteWorkflow = (id: string) => {
    setWorkflows((s: Workflow[]) => s.filter((w: Workflow) => w.id !== id))
    if (activeId === id) setActiveId(null)
  }

  const reorderWorkflows = (fromId: string, toId: string) => {
    if (fromId === toId) return

    setWorkflows((s: Workflow[]) => {
      const fromIndex = s.findIndex((w: Workflow) => w.id === fromId)
      const toIndex = s.findIndex((w: Workflow) => w.id === toId)

      if (fromIndex < 0 || toIndex < 0) return s

      const next = [...s]
      const [moved] = next.splice(fromIndex, 1)
      next.splice(toIndex, 0, moved)
      return next
    })
  }

  const active = workflows.find((w: Workflow) => w.id === activeId) ?? null

  return (
    <div className="app">
      <aside className="sidebar">
        <h1>Workflows</h1>
        <WorkflowList
          workflows={workflows}
          activeId={activeId}
          onSelect={setActiveId}
          onDelete={deleteWorkflow}
          onReorder={reorderWorkflows}
        />
        <NewWorkflowForm onCreate={addWorkflow} />
      </aside>
      <main className="main">
        {active ? (
          <TodoList
            workflow={active}
            onChange={(w: Workflow) => updateWorkflow(active.id, () => w)}
            onClearCompleted={() => removeCompletedFromWorkflow(active.id)}
          />
        ) : (
          <div className="empty">No workflows. Create one to get started.</div>
        )}
      </main>
    </div>
  )
}
