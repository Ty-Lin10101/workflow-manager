import React, { useEffect, useState } from 'react'
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
  const [dropTargetId, setDropTargetId] = useState<string | null>(null)
  const displayedWorkflows =
    sortMode === 'alphabetical'
      ? [...workflows].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
      : workflows

  useEffect(() => {
    if (!draggedId) return

    const getWorkflowId = (event: PointerEvent) => {
      const target = document.elementFromPoint(event.clientX, event.clientY)
      return target instanceof Element
        ? target.closest<HTMLElement>('[data-workflow-id]')?.dataset.workflowId ?? null
        : null
    }
    const handlePointerMove = (event: PointerEvent) => {
      const targetId = getWorkflowId(event)
      setDropTargetId((current) => (current === targetId ? current : targetId))
    }
    const handlePointerUp = (event: PointerEvent) => {
      const targetId = getWorkflowId(event)
      if (sortMode === 'manual' && targetId) onReorder(draggedId, targetId)
      setDraggedId(null)
      setDropTargetId(null)
    }
    const handlePointerCancel = () => {
      setDraggedId(null)
      setDropTargetId(null)
    }

    window.addEventListener('pointermove', handlePointerMove)
    window.addEventListener('pointerup', handlePointerUp)
    window.addEventListener('pointercancel', handlePointerCancel)
    return () => {
      window.removeEventListener('pointermove', handlePointerMove)
      window.removeEventListener('pointerup', handlePointerUp)
      window.removeEventListener('pointercancel', handlePointerCancel)
    }
  }, [draggedId, onReorder, sortMode])

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
            data-workflow-id={w.id}
            className={`workflow ${w.id === activeId ? 'active' : ''} ${draggedId === w.id ? 'dragging' : ''} ${dropTargetId === w.id ? 'drop-target' : ''}`}
          >
            {sortMode === 'manual' && (
              <span
                className="drag-indicator"
                title="Drag to reorder"
                onPointerDown={(e) => {
                  e.preventDefault()
                  setDraggedId(w.id)
                  setDropTargetId(w.id)
                }}
              >
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
