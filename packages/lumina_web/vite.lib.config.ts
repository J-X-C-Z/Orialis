import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'node:path';
export default defineConfig({ plugins: [react()], build: { outDir: 'lib-dist', lib: { entry: path.resolve(__dirname, 'src/index.tsx'), name: 'LuminaWeb', formats: ['es'], fileName: 'index' }, rollupOptions: { external: ['react', 'react-dom', 'react/jsx-runtime'] } } });
