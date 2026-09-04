import { describe, expect, it } from 'vitest';
import {
  createConfiguredOpenFoodFactsClient,
  validateOpenFoodFactsContactEmail,
} from './open-food-facts.js';

const barcode = '3017620422003';

describe('Open Food Facts composition boundary', () => {
  it.each([
    ['disabled', { OPEN_FOOD_FACTS_ENABLED: 'false', OPEN_FOOD_FACTS_CONTACT_EMAIL: 'operator@example.test' }],
    ['missing contact', { OPEN_FOOD_FACTS_ENABLED: 'true' }],
    ['invalid contact', { OPEN_FOOD_FACTS_ENABLED: 'true', OPEN_FOOD_FACTS_CONTACT_EMAIL: 'not-an-email' }],
  ])('fails closed without calling fetch when %s', async (_name, environment) => {
    const previousFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      throw new Error('network must not be reached');
    }) as typeof fetch;
    try {
      const result = await createConfiguredOpenFoodFactsClient(environment).lookup(barcode);
      expect(result).toMatchObject({ state: 'unavailable', reason: 'configuration_unavailable' });
      expect(calls).toBe(0);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  it('uses a valid contact only in the required User-Agent when explicitly enabled', async () => {
    const previousFetch = globalThis.fetch;
    const requests: Array<{ input: string | URL; init?: RequestInit }> = [];
    globalThis.fetch = (async (input, init) => {
      requests.push({ input, init });
      return new Response(JSON.stringify({
        status: 'success',
        product: {
          product_name_de: 'Beispiel',
          nutriments: {
            'energy-kcal_100g': 100,
            proteins_100g: 5,
            carbohydrates_100g: 10,
            fat_100g: 2,
          },
        },
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    }) as typeof fetch;
    const email = 'lifeos.operator@example.test';
    try {
      const result = await createConfiguredOpenFoodFactsClient({
        OPEN_FOOD_FACTS_ENABLED: 'true',
        OPEN_FOOD_FACTS_CONTACT_EMAIL: email,
      }).lookup(barcode);
      expect(result).toMatchObject({ state: 'found', barcode });
      expect(requests).toHaveLength(1);
      const headers = new Headers(requests[0]!.init?.headers);
      expect(headers.get('user-agent')).toBe(`LifeOS/0.2 (${email})`);
      expect(JSON.stringify(result)).not.toContain(email);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  it('rejects whitespace, control characters, malformed domains, and oversized contacts', () => {
    expect(validateOpenFoodFactsContactEmail(' operator@example.test')).toBeUndefined();
    expect(validateOpenFoodFactsContactEmail('operator@example.test\n')).toBeUndefined();
    expect(validateOpenFoodFactsContactEmail('operator@example')).toBeUndefined();
    expect(validateOpenFoodFactsContactEmail(`operator@${'a'.repeat(250)}.test`)).toBeUndefined();
    expect(validateOpenFoodFactsContactEmail('operator@example.test')).toBe('operator@example.test');
  });
});
