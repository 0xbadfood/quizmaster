import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 9060,
    strictPort: true,
    proxy: {
      '/api': 'http://127.0.0.1:9061',
      '/artifacts': 'http://127.0.0.1:9061',
      '/bundles': 'http://127.0.0.1:9061',
      '/studio-assets': 'http://127.0.0.1:9061',
      '/provider-tests': 'http://127.0.0.1:9061',
    },
  },
})
