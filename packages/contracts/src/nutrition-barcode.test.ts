import { describe, expect, it } from 'vitest';
import {
  NutritionBarcodeLookup,
  normalizeNutritionBarcode,
} from './nutrition-barcode.js';

const provenance = {
  source: 'openfoodfacts' as const,
  apiVersion: 'v3.6' as const,
  apiURL: 'https://world.openfoodfacts.org/api/v3.6/product/3017620422003.json',
  fetchedAt: new Date().toISOString(),
  databaseLicense: 'ODbL-1.0' as const,
  contentLicense: 'DbCL-1.0' as const,
  dataQualityWarning: 'Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed.' as const,
  attribution: 'Product data from Open Food Facts; database ODbL, contents DbCL.',
};

describe('nutrition barcode contract', () => {
  it('validates EAN-13 and EAN-8 checksums and canonicalizes UPC-A', () => {
    expect(normalizeNutritionBarcode('3017620422003')).toBe('3017620422003');
    expect(normalizeNutritionBarcode(' 30-17620422003 ')).toBe('3017620422003');
    expect(normalizeNutritionBarcode('96385074')).toBe('96385074');
    expect(normalizeNutritionBarcode('042100005264')).toBe('0042100005264');
    expect(normalizeNutritionBarcode('3017620422004')).toBeUndefined();
    expect(normalizeNutritionBarcode('301762042200')).toBeUndefined();
    expect(normalizeNutritionBarcode('3017620422003/other')).toBeUndefined();
  });

  it('keeps missing nutrients missing and rejects unknown response fields', () => {
    const result = NutritionBarcodeLookup.parse({
      schemaVersion: 1,
      state: 'found',
      barcode: '3017620422003',
      product: { name: 'Nutella', brand: 'Ferrero' },
      nutritionState: 'partial',
      per100g: { kcal: 539, proteinGrams: 6.3 },
      provenance,
    });
    expect(result.state).toBe('found');
    if (result.state === 'found') {
      expect(result.per100g?.carbsGrams).toBeUndefined();
      expect(result.per100g?.fatGrams).toBeUndefined();
    }
    expect(() => NutritionBarcodeLookup.parse({
      schemaVersion: 1,
      state: 'not_found',
      barcode: '3017620422003',
      provenance,
      raw: { product: 'must not cross boundary' },
    })).toThrow();
  });

  it('represents not-found and upstream-unavailable states without product data', () => {
    expect(NutritionBarcodeLookup.parse({
      schemaVersion: 1,
      state: 'not_found',
      barcode: '3017620422003',
      provenance,
    }).state).toBe('not_found');
    expect(NutritionBarcodeLookup.parse({
      schemaVersion: 1,
      state: 'unavailable',
      barcode: '3017620422003',
      reason: 'upstream_rate_limited',
      retryAfterSeconds: 15,
      provenance,
    }).state).toBe('unavailable');
  });

  it('requires a complete four-metric basis and explicit quality flags', () => {
    const base = {
      schemaVersion: 1,
      state: 'found' as const,
      barcode: '3017620422003',
      product: { name: 'Example' },
      provenance,
    };
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'complete', per100g: { kcal: 100, proteinGrams: 5, carbsGrams: 10 } })).toThrow();
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'partial', per100g: { kcal: 100, proteinGrams: 5, carbsGrams: 10, fatGrams: 2 } })).toThrow();
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'unreliable', per100g: { kcal: 100 }, qualityFlags: [] })).toThrow();
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'unreliable', per100g: { kcal: 100 }, qualityFlags: ['provider_quality_warning'] })).not.toThrow();
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'complete', per100g: { kcal: 1_001, proteinGrams: 5, carbsGrams: 10, fatGrams: 2 } })).toThrow();
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'complete', per100g: { kcal: 100, proteinGrams: 101, carbsGrams: 10, fatGrams: 2 } })).toThrow();
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'complete', perServing: { kcal: 5_001, proteinGrams: 5, carbsGrams: 10, fatGrams: 2 } })).toThrow();
    expect(() => NutritionBarcodeLookup.parse({ ...base, nutritionState: 'complete', perServing: { kcal: 100, proteinGrams: 2_001, carbsGrams: 10, fatGrams: 2 } })).toThrow();
  });
});
