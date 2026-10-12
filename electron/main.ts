import { app, BrowserWindow } from 'electron'
import * as path from 'path'

function createWindow() {
  const win = new BrowserWindow({
    width: 1000,
    height: 700,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js')
    }
  })

  const devUrl = 'http://localhost:5173'
  if (process.env.NODE_ENV === 'development') {
    win.loadURL(devUrl)
  } else {
    win.loadFile(path.join(__dirname, '../index.html'))
  }
}

app.whenReady().then(() => {
  createWindow()
  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit()
})
