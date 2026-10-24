import { defineConfig } from "vite";
export default defineConfig({
  server: {
    proxy: {
      "/api": {
        target: process.env.ORIALIS_API_URL || "http://127.0.0.1:18443",
        changeOrigin: true,
      },
    },
  },
});
