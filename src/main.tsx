import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
// @ts-ignore CSS is loaded by the bundler and has no TypeScript declarations.
import './styles.css'

const root = createRoot(document.getElementById('root')!)
root.render(<App />)
