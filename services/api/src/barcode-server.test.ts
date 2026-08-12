import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { createApiServer } from './server.js';
import { OpenFoodFactsClient } from './open-food-facts.js';

const barcode = '3017620422003';

function call(port: number, path: string) {
  return new Promise<{ status: number; body: any }>(resolve => {
    const req = request({ port, method: 'GET', path }, response => {
      let body = '';
      response.on('data', chunk => body += chunk);
      response.on('end', () => resolve({ status: response.statusCode!, body: JSON.parse(body) }));
    });
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
    await new Promise<void>(resolve => server.listen(0, resolve));
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
    await new Promise(resolve => server.close(resolve));
  });
});
