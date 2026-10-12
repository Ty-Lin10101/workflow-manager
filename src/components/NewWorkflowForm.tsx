import React, { useState } from 'react'
import { Workflow, createId } from '../models'

type Props = {
  onCreate: (wf: Workflow) => void
}

export default function NewWorkflowForm({ onCreate }: Props) {
  const [name, setName] = useState('')

  const submit = (e: React.FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return
    const wf: Workflow = { id: createId(), name: name.trim(), todos: [] }
    onCreate(wf)
    setName('')
  }

  return (
    <form className="new-workflow" onSubmit={submit}>
      <input value={name} onChange={(e) => setName(e.target.value)} placeholder="New workflow name" />
      <button type="submit">Add</button>
    </form>
  )
}
