const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('electron', {
  loadWorkflows: () => ipcRenderer.invoke('load-workflows'),
  saveWorkflows: (data) => ipcRenderer.invoke('save-workflows', { data })
})
