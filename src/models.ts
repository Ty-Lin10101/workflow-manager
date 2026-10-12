export type TodoItem = {
  id: string
  description: string
  due?: string // ISO datetime
  durationMinutes?: number
  notes?: string
  completed: boolean
}

export type Workflow = {
  id: string
  name: string
  todos: TodoItem[]
}

export const createId = () => crypto.randomUUID()

export const ensureUniqueTaskIds = (workflows: Workflow[]): Workflow[] => {
  const seen = new Set<string>()

  return workflows.map((workflow: Workflow) => ({
    ...workflow,
    todos: workflow.todos.map((todo: TodoItem) => {
      let nextId = todo.id

      if (!nextId || seen.has(nextId)) {
        nextId = createId()
      }

      seen.add(nextId)
      return { ...todo, id: nextId }
    })
  }))
}
