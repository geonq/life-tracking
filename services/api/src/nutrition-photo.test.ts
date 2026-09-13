import { describe, expect, it } from 'vitest';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { GoogleFoodPhotoProposalClient, NutritionPhotoProposalError, createConfiguredNutritionPhotoProposalClient } from './nutrition-photo.js';

const manifest = {
  schemaVersion: 1,
  mealID: 'meal-photo-1',
  requestID: 'request-photo-1',
  capturedAt: new Date().toISOString(),
  clientTimeZone: 'Europe/Berlin',
  inferenceConsent: true,
  images: [{
    imageID: 'image-1',
    mimeType: 'image/jpeg',
    byteLength: 1,
    width: 100,
    height: 100,
    sanitized: true,
    inlineDataBase64: 'AA==',
    sha256: 'a'.repeat(64),
  }],
} as const;

const providerBody = {
  items: [{
    itemID: 'item-1',
    estimatedLabel: 'Plain yogurt',
    labelSource: 'recognized',
    quantity: 1,
    unit: 'portion',
    grams: { estimate: 100, min: 90, max: 110 },
    calories: { estimate: 100, min: 90, max: 110 },
    protein: { estimate: 5, min: 4, max: 6 },
    carbs: { estimate: 10, min: 8, max: 12 },
    fat: { estimate: 2, min: 1, max: 3 },
    confidence: 'medium',
    flags: ['needs_confirmation'],
  }],
  totals: {
    grams: { estimate: 100, min: 90, max: 110 },
    calories: { estimate: 100, min: 90, max: 110 },
    protein: { estimate: 5, min: 4, max: 6 },
    carbs: { estimate: 10, min: 8, max: 12 },
    fat: { estimate: 2, min: 1, max: 3 },
  },
  flags: ['needs_confirmation'],
};

describe('Google food-photo proposal adapter', () => {
  it('fails closed without the explicit feature flag and key', async () => {
    const client = createConfiguredNutritionPhotoProposalClient({});
    await expect(client.generate(manifest)).rejects.toMatchObject({ code: 'configuration_unavailable' });
  });

  it('loads an enabled Google key from a regular protected file and ignores raw env keys', async () => {
    const directory = mkdtempSync(join(tmpdir(), 'lifeos-google-key-'));
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'file-google-key\n', { mode: 0o600 });
    const fileClient = createConfiguredNutritionPhotoProposalClient({
      GOOGLE_AI_STUDIO_ENABLED: 'true',
      GOOGLE_AI_STUDIO_API_KEY_FILE: keyPath,
      GOOGLE_AI_STUDIO_FOOD_MODEL: 'gemini-test',
    }, {
      fetch: async (_input, init) => {
        expect((init?.headers as Record<string, string>)['x-goog-api-key']).toBe('file-google-key');
        return new Response(JSON.stringify({
          candidates: [{ content: { parts: [{ text: JSON.stringify(providerBody) }] } }],
        }), { status: 200 });
      },
    });
    await expect(fileClient.generate(manifest)).resolves.toMatchObject({ state: 'needs_confirmation' });

    const rawOnlyClient = createConfiguredNutritionPhotoProposalClient({
      GOOGLE_AI_STUDIO_ENABLED: 'true',
      GOOGLE_AI_STUDIO_API_KEY: 'raw-google-key',
      GOOGLE_AI_STUDIO_FOOD_MODEL: 'gemini-test',
    });
    await expect(rawOnlyClient.generate(manifest)).rejects.toMatchObject({ code: 'configuration_unavailable' });
  });

  it('keeps the provider key in a header, canonicalizes lineage, and validates the returned proposal', async () => {
    let receivedURL = '';
    let receivedKey = '';
    const client = new GoogleFoodPhotoProposalClient({
      apiKey: 'test-google-key',
      model: 'gemini-test',
      now: () => Date.parse(manifest.capturedAt) + 1_000,
      fetch: async (input, init) => {
        receivedURL = String(input);
        receivedKey = String((init?.headers as Record<string, string>)['x-goog-api-key']);
        const request = JSON.parse(String(init?.body));
        expect(request.contents[0].parts[1].inline_data.data).toBe('AA==');
        expect(request.generationConfig.temperature).toBe(0.1);
        expect(request.generationConfig.responseSchema.properties.items.type).toBe('ARRAY');
        expect(request.generationConfig.responseSchema.properties.totals.required).toContain('calories');
        return new Response(JSON.stringify({
          candidates: [{ content: { parts: [{ text: JSON.stringify(providerBody) }] } }],
        }), { status: 200, headers: { 'content-type': 'application/json' } });
      },
    });

    const proposal = await client.generate(manifest);
    expect(receivedURL).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent');
    expect(receivedURL).not.toContain('test-google-key');
    expect(receivedKey).toBe('test-google-key');
    expect(proposal.mealID).toBe(manifest.mealID);
    expect(proposal.requestID).toBe(manifest.requestID);
    expect(proposal.provenance.provider).toBe('google-ai-studio');
    expect(proposal.provenance.sanitizedImageHashes).toEqual([{ imageID: 'image-1', sha256: 'a'.repeat(64) }]);
    expect(proposal.state).toBe('needs_confirmation');
  });

  it('rejects a provider response that does not match the strict food body', async () => {
    const client = new GoogleFoodPhotoProposalClient({
      apiKey: 'test-google-key',
      model: 'gemini-test',
      fetch: async () => new Response(JSON.stringify({
        candidates: [{ content: { parts: [{ text: JSON.stringify({ ...providerBody, extra: true }) }] } }],
      }), { status: 200 }),
    });
    await expect(client.generate(manifest)).rejects.toBeInstanceOf(NutritionPhotoProposalError);
  });
});
