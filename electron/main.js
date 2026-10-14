const { app, BrowserWindow, ipcMain } = require('electron')
const path = require('path')
const fs = require('fs')

function dataFilePath() {
  const dir = app.getPath('userData')
  return path.join(dir, 'workflows.json')
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1000,
    height: 700,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true
    }
  })

  const devUrl = process.env.VITE_DEV_SERVER_URL || 'http://127.0.0.1:5173'
  if (process.env.NODE_ENV === 'development' || process.env.VITE_DEV_SERVER_URL) {
    void win.loadURL(devUrl).catch((error) => {
      console.error('Failed to load the Electron development server:', error)
    })
  } else {
    void win.loadFile(path.join(__dirname, '../dist/index.html')).catch((error) => {
      console.error('Failed to load the built Electron frontend:', error)
    })
  }
}

ipcMain.handle('load-workflows', async () => {
  const p = dataFilePath()
  try {
    return await fs.promises.readFile(p, 'utf8')
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
})

ipcMain.handle('save-workflows', async (_, { data }) => {
  if (typeof data !== 'string') {
    throw new TypeError('Workflow data must be a string')
  }

  const p = dataFilePath()
  await fs.promises.mkdir(path.dirname(p), { recursive: true })
  await fs.promises.writeFile(p, data, 'utf8')
  return true
})

app.whenReady().then(() => {
  createWindow()
  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit()
})
