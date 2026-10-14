import React, { useMemo, useState } from 'react'
import { Workflow, TodoItem } from '../models'
import NewTodoForm from './NewTodoForm'

type SortMode = 'manual' | 'due' | 'duration' | 'completed'
type FilterMode = 'all' | 'active' | 'completed'

type Props = {
  workflow: Workflow
  onChange: (w: Workflow) => void
  onClearCompleted: () => void
}

export default function TodoList({ workflow, onChange, onClearCompleted }: Props) {
  const [sortMode, setSortMode] = useState<SortMode>('manual')
  const [filterMode, setFilterMode] = useState<FilterMode>('all')
  const [draggedId, setDraggedId] = useState<string | null>(null)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editDraft, setEditDraft] = useState({
    description: '',
    due: '',
    durationMinutes: '' as number | '',
    notes: ''
  })

  const startEditing = (task: TodoItem) => {
    setEditingId(task.id)
    setEditDraft({
      description: task.description,
      due: task.due ?? '',
      durationMinutes: task.durationMinutes ?? '',
      notes: task.notes ?? ''
    })
  }

  const saveEdit = (id: string) => {
    const nextDescription = editDraft.description.trim()
    if (!nextDescription) return

    onChange({
      ...workflow,
      todos: workflow.todos.map((t: TodoItem) =>
        t.id === id
          ? {
              ...t,
              description: nextDescription,
              due: editDraft.due || undefined,
              durationMinutes: editDraft.durationMinutes === '' ? undefined : editDraft.durationMinutes,
              notes: editDraft.notes || undefined
            }
          : t
      )
    })

    setEditingId(null)
    setEditDraft({ description: '', due: '', durationMinutes: '', notes: '' })
  }

  const reorderTodos = (fromId: string, toId: string) => {
    if (fromId === toId) return

    const next = [...workflow.todos]
    const fromIndex = next.findIndex((t: TodoItem) => t.id === fromId)
    const toIndex = next.findIndex((t: TodoItem) => t.id === toId)

    if (fromIndex < 0 || toIndex < 0) return

    const [moved] = next.splice(fromIndex, 1)
    next.splice(toIndex, 0, moved)
    onChange({ ...workflow, todos: next })
  }

  const visibleTodos = useMemo(() => {
    const filtered = workflow.todos.filter((t: TodoItem) => {
      if (filterMode === 'active') return !t.completed
      if (filterMode === 'completed') return t.completed
      return true
    })

    if (sortMode === 'manual') {
      return filtered
    }

    const sorted = [...filtered]
    sorted.sort((a: TodoItem, b: TodoItem) => {
      if (sortMode === 'due') {
        const aTime = a.due ? new Date(a.due).getTime() : Number.MAX_SAFE_INTEGER
        const bTime = b.due ? new Date(b.due).getTime() : Number.MAX_SAFE_INTEGER
        return aTime - bTime
      }

      if (sortMode === 'duration') {
        const aMinutes = a.durationMinutes ?? Number.MAX_SAFE_INTEGER
        const bMinutes = b.durationMinutes ?? Number.MAX_SAFE_INTEGER
        return aMinutes - bMinutes
      }

      if (sortMode === 'completed') {
        return Number(a.completed) - Number(b.completed)
      }

      return 0
    })

    return sorted
  }, [filterMode, sortMode, workflow.todos])

  const addTodo = (t: TodoItem) => {
    onChange({ ...workflow, todos: [...workflow.todos, t] })
  }

  const toggle = (id: string) => {
    onChange({
      ...workflow,
      todos: workflow.todos.map((t: TodoItem) => (t.id === id ? { ...t, completed: !t.completed } : t))
    })
  }

  const remove = (id: string) => {
    onChange({ ...workflow, todos: workflow.todos.filter((t) => t.id !== id) })
  }

  return (
    <div className="todo-container">
      <header>
        <h2>{workflow.name}</h2>
        <div className="controls">
          <button onClick={onClearCompleted}>Clear all finished tasks</button>
        </div>
      </header>

      <div className="todo-toolbar">
        <label>
          Sort
          <select value={sortMode} onChange={(e) => setSortMode(e.target.value as SortMode)}>
            <option value="manual">Manual</option>
            <option value="due">Due date</option>
            <option value="duration">Duration</option>
            <option value="completed">Completion</option>
          </select>
        </label>

        <label>
          Filter
          <select value={filterMode} onChange={(e) => setFilterMode(e.target.value as FilterMode)}>
            <option value="all">All</option>
            <option value="active">Active</option>
            <option value="completed">Completed</option>
          </select>
        </label>
      </div>

      <NewTodoForm onCreate={addTodo} />

      <ul className="todos">
        {visibleTodos.map((t: TodoItem) => (
          <li
            key={t.id}
            className={`todo ${t.completed ? 'done' : ''} ${draggedId === t.id ? 'dragging' : ''}`}
            draggable={sortMode === 'manual'}
            onDragStart={() => sortMode === 'manual' && setDraggedId(t.id)}
            onDragEnd={() => setDraggedId(null)}
            onDragOver={(e) => {
              if (sortMode === 'manual') e.preventDefault()
            }}
            onDrop={() => {
              if (sortMode === 'manual' && draggedId) {
                reorderTodos(draggedId, t.id)
                setDraggedId(null)
              }
            }}
          >
            {sortMode === 'manual' && (
              <span className="drag-indicator" aria-hidden="true" title="Drag to reorder">
                ⋮⋮
              </span>
            )}
            {editingId === t.id ? (
              <div className="todo-edit-form">
                <input
                  value={editDraft.description}
                  onChange={(e) => setEditDraft((d) => ({ ...d, description: e.target.value }))}
                  placeholder="Task description"
                />
                <input
                  type="datetime-local"
                  value={editDraft.due}
                  onChange={(e) => setEditDraft((d) => ({ ...d, due: e.target.value }))}
                />
                <input
                  type="number"
                  min={1}
                  value={editDraft.durationMinutes as number | ''}
                  onChange={(e) =>
                    setEditDraft((d) => ({
                      ...d,
                      durationMinutes: e.target.value ? Number(e.target.value) : ''
                    }))
                  }
                  placeholder="Minutes"
                />
                <input
                  value={editDraft.notes}
                  onChange={(e) => setEditDraft((d) => ({ ...d, notes: e.target.value }))}
                  placeholder="Notes"
                />
                <div className="actions">
                  <button onClick={() => saveEdit(t.id)}>Save</button>
                  <button onClick={() => setEditingId(null)}>Cancel</button>
                </div>
              </div>
            ) : (
              <>
                <input type="checkbox" checked={t.completed} onChange={() => toggle(t.id)} />
                <div className="todo-body">
                  <div className="desc">{t.description}</div>
                  <div className="meta">{t.due ? new Date(t.due).toLocaleString() : ''} {t.durationMinutes ? `· ${t.durationMinutes}m` : ''}</div>
                  {t.notes ? <div className="notes">{t.notes}</div> : null}
                </div>
                <div className="actions">
                  <button onClick={() => startEditing(t)}>Edit</button>
                  <button onClick={() => remove(t.id)}>Delete</button>
                </div>
              </>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}
