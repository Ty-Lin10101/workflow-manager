declare global {
  interface Window {
    electron?: {
      loadWorkflows?: () => Promise<string | null>
      saveWorkflows?: (data: string) => Promise<boolean>
    }
  }
}

export {}
