import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const securityHeaders = {
  'Content-Security-Policy': "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https://geonqserver.tail5f8789.ts.net;",
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()'
};

export default defineConfig({
  plugins: [react()],
  server: { headers: securityHeaders, proxy: { '/api': 'http://127.0.0.1:8787' } },
  preview: { headers: securityHeaders, proxy: { '/api': 'http://127.0.0.1:8787' } },
});
