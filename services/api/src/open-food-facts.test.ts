import { describe, expect, it } from 'vitest';
import { OpenFoodFactsClient } from './open-food-facts.js';

const barcode = '3017620422003';
const jsonResponse = (status: number, body: unknown, headers: Record<string, string> = {}) => new Response(
  typeof body === 'string' ? body : JSON.stringify(body),
  { status, headers: { 'content-type': 'application/json', ...headers } },
);

const germanProduct = {
  status: 'success',
  product: {
    code: barcode,
    product_name_de: 'Haselnusscreme',
    product_name: 'Hazelnut spread',
    brands: 'Beispiel',
    quantity: '400 g',
    serving_size: '15 g',
    countries_tags: ['en:germany'],
    nutriments: {
      'energy-kcal_100g': 539,
      proteins_100g: 6.3,
      carbohydrates_100g: 57.5,
      fat_100g: 30.9,
      'energy-kcal_serving': 81,
      proteins_serving: 0.95,
      carbohydrates_serving: 8.63,
      fat_serving: 4.64,
    },
    data_quality_errors_tags: [],
    data_quality_warnings_tags: [],
    image_front_small_url: 'https://untrusted.example/image.jpg',
    email: 'must-not-cross-boundary@example.com',
  },
  secret: 'must-not-cross-boundary',
};

describe('Open Food Facts barcode adapter', () => {
  it('requests v3.6 with German localization, a bounded field list, manual redirects, and a real contact UA', async () => {
    let seenURL: URL | undefined;
    let seenInit: RequestInit | undefined;
    const client = new OpenFoodFactsClient({
      contactEmail: 'lifeos-test@example.com',
      fetch: async (input, init) => {
        seenURL = new URL(input);
        seenInit = init;
        return jsonResponse(200, germanProduct);
      },
    });
    const result = await client.lookup(barcode);
    expect(result).toMatchObject({ state: 'found', barcode, nutritionState: 'complete' });
    if (result.state === 'found') {
      expect(result.product).toEqual({
        name: 'Haselnusscreme', brand: 'Beispiel', quantity: '400 g',
        servingSize: '15 g', countriesTags: ['en:germany'],
      });
      expect(result.per100g).toEqual({ kcal: 539, proteinGrams: 6.3, carbsGrams: 57.5, fatGrams: 30.9 });
      expect(result.perServing).toEqual({ kcal: 81, proteinGrams: 0.95, carbsGrams: 8.63, fatGrams: 4.64 });
      expect(result.provenance.databaseLicense).toBe('ODbL-1.0');
      expect(result.provenance.contentLicense).toBe('DbCL-1.0');
      expect(result.provenance.dataQualityWarning).toMatch(/volunteer-sourced/);
      expect(JSON.stringify(result)).not.toMatch(/untrusted\.example|must-not-cross-boundary|email/);
    }
    expect(seenURL?.pathname).toBe(`/api/v3.6/product/${barcode}.json`);
    expect(seenURL?.searchParams.get('lc')).toBe('de');
    expect(seenURL?.searchParams.get('cc')).toBe('de');
    expect(seenURL?.searchParams.get('tags_lc')).toBe('de');
    expect(seenURL?.searchParams.get('product_type')).toBe('food');
    expect(seenURL?.searchParams.get('fields')).toMatch(/nutriments/);
    expect(seenInit?.method).toBe('GET');
    expect(seenInit?.body).toBeUndefined();
    expect(seenInit?.redirect).toBe('manual');
    expect(new Headers(seenInit?.headers).get('user-agent')).toBe('LifeOS/0.2 (lifeos-test@example.com)');
  });

  it('maps HTTP 404 to not-found and a valid product with missing macros to partial', async () => {
    const notFound = new OpenFoodFactsClient({ contactEmail: 'lifeos-test@example.com', fetch: async () => jsonResponse(404, {}) });
    expect((await notFound.lookup(barcode)).state).toBe('not_found');
    const partial = new OpenFoodFactsClient({ contactEmail: 'lifeos-test@example.com', fetch: async () => jsonResponse(200, {
      status: 'success', product: { product_name_de: 'Teilweise', nutriments: { 'energy-kcal_100g': 120 }, data_quality_errors_tags: [], data_quality_warnings_tags: [] },
    }) });
    const result = await partial.lookup(barcode);
    expect(result).toMatchObject({ state: 'found', nutritionState: 'partial' });
    if (result.state === 'found') expect(result.per100g).toEqual({ kcal: 120 });
  });

  it('folds provider warnings/errors into unreliable without inventing values', async () => {
    const client = new OpenFoodFactsClient({ contactEmail: 'lifeos-test@example.com', fetch: async () => jsonResponse(200, {
      status: 'success_with_warnings',
      warnings: [{ message: 'provider warning' }],
      product: { product_name_de: 'Warnung', nutriments: { 'energy-kcal_100g': 200, proteins_100g: 5, carbohydrates_100g: 20, fat_100g: 4 }, data_quality_errors_tags: [], data_quality_warnings_tags: [] },
    }) });
    const result = await client.lookup(barcode);
    expect(result).toMatchObject({ state: 'found', nutritionState: 'unreliable', qualityFlags: ['provider_quality_warning'] });
  });

  it('marks out-of-range provider nutrients unreliable instead of accepting them', async () => {
    const client = new OpenFoodFactsClient({ contactEmail: 'lifeos-test@example.com', fetch: async () => jsonResponse(200, {
      status: 'success',
      product: {
        product_name_de: 'Ungültige Werte',
        nutriments: { 'energy-kcal_100g': 1_001, proteins_100g: 101, carbohydrates_100g: 10, fat_100g: 2 },
        data_quality_errors_tags: [], data_quality_warnings_tags: [],
      },
    }) });
    const result = await client.lookup(barcode);
    expect(result).toMatchObject({ state: 'found', nutritionState: 'unreliable', qualityFlags: ['provider_quality_error'] });
    if (result.state === 'found') expect(result.per100g).toEqual({ carbsGrams: 10, fatGrams: 2 });
  });

  it('fails closed for malformed, oversized, redirect, 429, and 503 upstream responses', async () => {
    const cases: Array<[string, () => Promise<Response>, string]> = [
      ['malformed', async () => jsonResponse(200, '{not-json'), 'invalid_response'],
      ['oversized', async () => jsonResponse(200, '{}', { 'content-length': String(256 * 1024 + 1) }), 'upstream_oversized'],
      ['redirect', async () => new Response('', { status: 302, headers: { location: 'https://evil.example' } }), 'upstream_redirect'],
      ['rate limited', async () => jsonResponse(429, {}), 'upstream_rate_limited'],
      ['service unavailable', async () => jsonResponse(503, {}), 'upstream_unavailable'],
    ];
    for (const [, fetcher, reason] of cases) {
      const client = new OpenFoodFactsClient({ contactEmail: 'lifeos-test@example.com', fetch: fetcher });
      expect(await client.lookup(barcode)).toMatchObject({ state: 'unavailable', reason });
    }
  });

  it('applies the deadline while consuming a slow response body', async () => {
    let signal: AbortSignal | undefined;
    const client = new OpenFoodFactsClient({
      contactEmail: 'lifeos-test@example.com',
      timeoutMs: 10,
      fetch: async (_input, init) => {
        signal = init?.signal as AbortSignal;
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            signal!.addEventListener('abort', () => {
              const error = new Error('body aborted');
              error.name = 'AbortError';
              controller.error(error);
            }, { once: true });
          },
        });
        return new Response(body, { status: 200 });
      },
    });

    await expect(client.lookup(barcode)).resolves.toMatchObject({
      state: 'unavailable',
      reason: 'upstream_timeout',
    });
    expect(signal?.aborted).toBe(true);
  });

  it('requires explicit contact configuration, caches products, and backs off after 429', async () => {
    let requests = 0;
    const noContact = new OpenFoodFactsClient({ fetch: async () => { requests += 1; return jsonResponse(200, germanProduct); } });
    expect(await noContact.lookup(barcode)).toMatchObject({ state: 'unavailable', reason: 'configuration_unavailable' });
    expect(requests).toBe(0);

    let now = 1_000_000;
    let calls = 0;
    const client = new OpenFoodFactsClient({
      contactEmail: 'lifeos-test@example.com', now: () => now,
      fetch: async () => { calls += 1; return jsonResponse(429, {}); },
    });
    expect(await client.lookup(barcode)).toMatchObject({ state: 'unavailable', reason: 'upstream_rate_limited', retryAfterSeconds: 5 });
    expect(await client.lookup('042100005264')).toMatchObject({ state: 'unavailable', reason: 'upstream_rate_limited' });
    expect(calls).toBe(1);
    now += 5_001;
    expect(await client.lookup('042100005264')).toMatchObject({ state: 'unavailable', reason: 'upstream_rate_limited', retryAfterSeconds: 15 });
    expect(calls).toBe(2);

    let cacheCalls = 0;
    const cached = new OpenFoodFactsClient({ contactEmail: 'lifeos-test@example.com', fetch: async () => { cacheCalls += 1; return jsonResponse(200, germanProduct); } });
    await cached.lookup(barcode);
    await cached.lookup(` 30-17620422003 `);
    expect(cacheCalls).toBe(1);

    let evictions = 0;
    let evictionNow = 2_000_000;
    const bounded = new OpenFoodFactsClient({
      contactEmail: 'lifeos-test@example.com', now: () => evictionNow,
      fetch: async () => { evictions += 1; return jsonResponse(404, {}); },
    });
    const ean = (seed: number) => {
      const data = String(seed).padStart(12, '0').slice(-12);
      let sum = 0;
      for (let index = data.length - 1, weight = 3; index >= 0; index -= 1, weight = weight === 3 ? 1 : 3) sum += Number(data[index]) * weight;
      return `${data}${(10 - sum % 10) % 10}`;
    };
    const first = ean(1);
    for (let index = 1; index <= 1_001; index += 1) {
      await bounded.lookup(ean(index));
      evictionNow += 61_000;
    }
    const callsAfterFill = evictions;
    await bounded.lookup(first);
    expect(evictions).toBeGreaterThan(callsAfterFill);
  });
});
