import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
// Every px in the CSS follows the screen (720p .. 8K, ultrawide by height): ui-scale.cjs.
import uiScale from './ui-scale.cjs';
import { viteSingleFile } from 'vite-plugin-singlefile';

// It builds one self-contained index.html file (every JS/CSS inlined) inside web/build
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  base: './',
  css: { postcss: { plugins: [uiScale()] } },
  build: {
    outDir: 'build',
    emptyOutDir: true,
    // RedM's CEF is Chromium 87-class: the bundle's JS and CSS are lowered to it
    target: 'chrome87',
  },
});
