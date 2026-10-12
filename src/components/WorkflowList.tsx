import React, { useState } from 'react'
import { Workflow } from '../models'

type Props = {
  workflows: Workflow[]
  activeId: string | null
  onSelect: (id: string) => void
  onDelete: (id: string) => void
  onReorder: (fromId: string, toId: string) => void
}

export default function WorkflowList({ workflows, activeId, onSelect, onDelete, onReorder }: Props) {
  const [draggedId, setDraggedId] = useState<string | null>(null)

  return (
    <div className="workflow-list">
      {workflows.map((w: Workflow) => (
        <div
          key={w.id}
          className={`workflow ${w.id === activeId ? 'active' : ''} ${draggedId === w.id ? 'dragging' : ''}`}
          draggable
          onDragStart={() => setDraggedId(w.id)}
          onDragEnd={() => setDraggedId(null)}
          onDragOver={(e) => e.preventDefault()}
          onDrop={() => {
            if (draggedId) onReorder(draggedId, w.id)
            setDraggedId(null)
          }}
        >
          <button onClick={() => onSelect(w.id)} className="workflow-name">
            {w.name}
          </button>
          <button onClick={() => onDelete(w.id)} className="delete">×</button>
        </div>
      ))}
    </div>
  )
}
