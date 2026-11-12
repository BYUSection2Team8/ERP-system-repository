import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// GitHub Pages serves the site from /<repo-name>/, so asset paths need this prefix.
export default defineConfig({
  plugins: [react()],
  base: '/ERP-system-repository/',
});
