import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { createApiServer } from './server.js';
import { OpenFoodFactsClient } from './open-food-facts.js';

const barcode = '3017620422003';

function call(port: number, path: string) {
  return new Promise<{ status: number; body: any }>((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port, method: 'GET', path }, response => {
      let body = '';
      response.on('data', chunk => body += chunk);
      response.on('end', () => resolve({ status: response.statusCode!, body: JSON.parse(body) }));
    });
    req.once('error', reject);
    req.setTimeout(5_000, () => req.destroy(new Error('barcode_request_timeout')));
    req.end();
  });
}

describe('barcode API route', () => {
  it('serves only the normalized proposal contract and rejects path/query injection', async () => {
    const client = new OpenFoodFactsClient({
      contactEmail: 'lifeos-test@example.com',
      fetch: async () => new Response(JSON.stringify({
        status: 'success',
        product: {
          product_name_de: 'Deutsches Beispiel',
          nutriments: { 'energy-kcal_100g': 100, proteins_100g: 5, carbohydrates_100g: 10, fat_100g: 2 },
          data_quality_errors_tags: [], data_quality_warnings_tags: [],
        },
      }), { status: 200, headers: { 'content-type': 'application/json' } }),
    });
    const server = createApiServer(async () => ({ connectorState: 'unavailable', windows: [] }), client);
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => { server.removeListener('error', onError); reject(error); };
      server.once('error', onError);
      server.listen(0, '127.0.0.1', () => { server.removeListener('error', onError); resolve(); });
    });
    try {
      const address = server.address();
      if (!address || typeof address === 'string') throw new Error('no address');
      const found = await call(address.port, `/api/nutrition/barcode/${barcode}`);
      expect(found.status).toBe(200);
      expect(found.body).toMatchObject({ state: 'found', barcode, product: { name: 'Deutsches Beispiel' } });
      expect(found.body).not.toHaveProperty('raw');
      const alias = await call(address.port, `/nutrition/barcode/${barcode}`);
      expect(alias.status).toBe(200);
      expect((await call(address.port, '/api/nutrition/barcode/not-a-barcode')).status).toBe(400);
      expect((await call(address.port, `/api/nutrition/barcode/${barcode}?redirect=https://evil.example`)).status).toBe(400);
      expect((await call(address.port, '/api/nutrition/barcode/%2F')).status).toBe(400);
    } finally {
      if (server.listening) await new Promise<void>(resolve => server.close(() => resolve()));
    }
  });

  it('fails closed on invalid UTF-8 and a provider product for a different barcode', async () => {
    const invalidUTF8 = Buffer.concat([
      Buffer.from('{"status":"success","product":{"product_name":"'),
      Buffer.from([0xff]),
      Buffer.from('"}}'),
    ]);
    const invalidBytesClient = new OpenFoodFactsClient({
      contactEmail: 'lifeos-test@example.com',
      fetch: async () => new Response(invalidUTF8, { status: 200 }),
    });
    await expect(invalidBytesClient.lookup(barcode)).resolves.toMatchObject({
      state: 'unavailable', reason: 'invalid_response',
    });

    const mismatchedProductClient = new OpenFoodFactsClient({
      contactEmail: 'lifeos-test@example.com',
      fetch: async () => new Response(JSON.stringify({
        status: 'success', product: { code: '96385074', product_name: 'wrong product' },
      }), { status: 200 }),
    });
    await expect(mismatchedProductClient.lookup(barcode)).resolves.toMatchObject({
      state: 'unavailable', reason: 'invalid_response',
    });
  });
});
