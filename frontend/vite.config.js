import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    proxy: {
      // In dev mode, proxy /prometheus → real Prometheus container
      '/prometheus': {
        target: 'http://prometheus:9090',
        rewrite: path => path.replace(/^\/prometheus/, ''),
        changeOrigin: true,
      }
    }
  },
  build: {
    outDir: 'dist',
  }
})