declare global {
  interface Window {
    electron?: {
      loadWorkflows?: () => Promise<string | null>
      saveWorkflows?: (data: string) => Promise<void>
    }
  }
}

declare module '@tauri-apps/api/tauri' {
  export function invoke(cmd: string, args?: any): Promise<any>
}

export {}
