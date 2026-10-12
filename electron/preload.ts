// Preload can expose safe APIs to renderer via contextBridge if needed
// For now we keep it minimal — persistence uses localStorage in renderer.
import { contextBridge } from 'electron'

contextBridge.exposeInMainWorld('electron', {
  // future API hooks
})
