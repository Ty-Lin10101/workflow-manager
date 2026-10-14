import React, { useState } from 'react'
import { Workflow } from '../models'

type SortMode = 'manual' | 'alphabetical'

type Props = {
  workflows: Workflow[]
  activeId: string | null
  onSelect: (id: string) => void
  onDelete: (id: string) => void
  onReorder: (fromId: string, toId: string) => void
}

export default function WorkflowList({ workflows, activeId, onSelect, onDelete, onReorder }: Props) {
  const [sortMode, setSortMode] = useState<SortMode>('manual')
  const [draggedId, setDraggedId] = useState<string | null>(null)
  const displayedWorkflows =
    sortMode === 'alphabetical'
      ? [...workflows].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
      : workflows

  return (
    <>
      <label className="workflow-sort">
        Sort
        <select value={sortMode} onChange={(e) => setSortMode(e.target.value as SortMode)}>
          <option value="manual">Manual</option>
          <option value="alphabetical">Alphabetical</option>
        </select>
      </label>
      <div className="workflow-list">
        {displayedWorkflows.map((w: Workflow) => (
          <div
            key={w.id}
            className={`workflow ${w.id === activeId ? 'active' : ''} ${draggedId === w.id ? 'dragging' : ''}`}
            draggable={sortMode === 'manual'}
            onDragStart={() => sortMode === 'manual' && setDraggedId(w.id)}
            onDragEnd={() => setDraggedId(null)}
            onDragOver={(e) => {
              if (sortMode === 'manual') e.preventDefault()
            }}
            onDrop={() => {
              if (sortMode === 'manual' && draggedId) onReorder(draggedId, w.id)
              setDraggedId(null)
            }}
          >
            {sortMode === 'manual' && (
              <span className="drag-indicator" aria-hidden="true" title="Drag to reorder">
                ⋮⋮
              </span>
            )}
            <button onClick={() => onSelect(w.id)} className="workflow-name">
              {w.name}
            </button>
            <button onClick={() => onDelete(w.id)} className="delete">×</button>
          </div>
        ))}
      </div>
    </>
  )
}
