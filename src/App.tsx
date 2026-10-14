import React, { useEffect, useState } from 'react'
import { Workflow, ensureUniqueTaskIds } from './models'
import WorkflowList from './components/WorkflowList'
import TodoList from './components/TodoList'
import NewWorkflowForm from './components/NewWorkflowForm'

const STORAGE_KEY = 'todo_desktop_workflows_v1'

function readLocalWorkflows(): Workflow[] {
  const raw = localStorage.getItem(STORAGE_KEY)
  return raw ? ensureUniqueTaskIds(JSON.parse(raw) as Workflow[]) : []
}

export default function App() {
  const [workflows, setWorkflows] = useState<Workflow[]>([])
  const [activeId, setActiveId] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [storageError, setStorageError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const load = async () => {
      try {
        let raw: string | null = null
        let tauri = false

        if (window.electron?.loadWorkflows) {
          raw = await window.electron.loadWorkflows()
        } else {
          const api = await import('@tauri-apps/api/core')
          tauri = api.isTauri()
          if (tauri) raw = await api.invoke<string | null>('load_workflows')
        }

        const storedWorkflows = raw
          ? ensureUniqueTaskIds(JSON.parse(raw) as Workflow[])
          : readLocalWorkflows()
        if (cancelled) return
        setWorkflows(storedWorkflows)

        if (tauri && !raw && storedWorkflows.length > 0) {
          const { invoke } = await import('@tauri-apps/api/core')
          await invoke('save_workflows', { data: JSON.stringify(storedWorkflows) })
        }
        if (!cancelled) setLoaded(true)
      } catch (error) {
        if (cancelled) return
        setLoadError(`Could not load saved workflows: ${String(error)}`)
        setLoaded(true)
      }
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    if (!loaded || loadError) return
    let cancelled = false
    const save = async () => {
      const payload = JSON.stringify(workflows)
      try {
        if (window.electron?.saveWorkflows) {
          await window.electron.saveWorkflows(payload)
        } else {
          const { invoke, isTauri } = await import('@tauri-apps/api/core')
          if (isTauri()) {
            await invoke('save_workflows', { data: payload })
          } else {
            localStorage.setItem(STORAGE_KEY, payload)
          }
        }
        if (!cancelled) setStorageError(null)
      } catch (error) {
        if (!cancelled) setStorageError(`Could not save workflows: ${String(error)}`)
      }
    }

    void save()
    return () => {
      cancelled = true
    }
  }, [workflows, loaded, loadError])

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
      {(loadError || storageError) && (
        <div className="storage-error" role="alert">
          {loadError || storageError}
        </div>
      )}
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
