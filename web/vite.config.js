import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { viteSingleFile } from 'vite-plugin-singlefile';

// It builds one self-contained index.html file (every JS/CSS inlined) inside web/build
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  base: './',
  build: {
    outDir: 'build',
    emptyOutDir: true,
    // RedM's CEF is Chromium 87-class: the bundle's JS and CSS are lowered to it
    target: 'chrome87',
  },
});
