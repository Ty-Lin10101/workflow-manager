import React, { useState } from 'react'
import { TodoItem, createId } from '../models'

type Props = {
  onCreate: (t: TodoItem) => void
}

export default function NewTodoForm({ onCreate }: Props) {
  const [description, setDescription] = useState('')
  const [due, setDue] = useState('')
  const [duration, setDuration] = useState<number | ''>('')
  const [notes, setNotes] = useState('')

  const submit = (e: React.FormEvent) => {
    e.preventDefault()
    if (!description.trim()) return
    const t: TodoItem = {
      id: createId(),
      description: description.trim(),
      due: due || undefined,
      durationMinutes: duration === '' ? undefined : duration,
      notes: notes || undefined,
      completed: false
    }
    onCreate(t)
    setDescription('')
    setDue('')
    setDuration('')
    setNotes('')
  }

  return (
    <form className="new-todo" onSubmit={submit}>
      <input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Task description" />
      <input type="datetime-local" value={due} onChange={(e) => setDue(e.target.value)} />
      <input type="number" min={1} placeholder="Duration (minutes)" value={duration as any} onChange={(e) => setDuration(e.target.value ? Number(e.target.value) : '')} />
      <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Notes (optional)" />
      <button type="submit">Add</button>
    </form>
  )
}
