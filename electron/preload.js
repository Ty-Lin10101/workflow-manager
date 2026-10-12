const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('electron', {
  loadWorkflows: async () => {
    try {
      const res = await ipcRenderer.invoke('load-workflows')
      return res || null
    } catch {
      return null
    }
  },
  saveWorkflows: async (data) => {
    try {
      await ipcRenderer.invoke('save-workflows', { data })
    } catch {
      // ignore
    }
  }
})
