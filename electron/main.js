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

  const devUrl = 'http://localhost:5173'
  if (process.env.NODE_ENV === 'development' || process.env.VITE_DEV_SERVER_URL) {
    win.loadURL(devUrl)
  } else {
    win.loadFile(path.join(__dirname, '../index.html'))
  }
}

ipcMain.handle('load-workflows', async () => {
  try {
    const p = dataFilePath()
    if (!fs.existsSync(p)) return null
    const raw = await fs.promises.readFile(p, 'utf8')
    return raw
  } catch (e) {
    return null
  }
})

ipcMain.handle('save-workflows', async (_, { data }) => {
  try {
    const p = dataFilePath()
    await fs.promises.mkdir(path.dirname(p), { recursive: true })
    await fs.promises.writeFile(p, data, 'utf8')
    return true
  } catch (e) {
    return false
  }
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
