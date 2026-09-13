import {
  NutritionBarcodeLookup,
  normalizeNutritionBarcode,
  type NutritionBarcodeLookupResponse,
  type NutritionBarcodeReason,
  type NutritionMacros,
  type NutritionPer100gMacros,
} from '@iphone-life-os/contracts';
import { parseStrictJSON } from './json-boundary.js';

const OPEN_FOOD_FACTS_ORIGIN = 'https://world.openfoodfacts.org';
const OPEN_FOOD_FACTS_API_VERSION = 'v3.6';
const MAX_RESPONSE_BYTES = 256 * 1024;
const REQUEST_TIMEOUT_MS = 5_000;
const REQUESTS_PER_MINUTE = 15;
const RATE_WINDOW_MS = 60_000;
const POSITIVE_CACHE_MS = 24 * 60 * 60_000;
const NEGATIVE_CACHE_MS = 10 * 60_000;
const FAILURE_CACHE_MS = 30_000;
const MAX_CACHE_ENTRIES = 1_000;
const MAX_CONTACT_EMAIL_LENGTH = 254;
const BACKOFF_STEPS_MS = [5_000, 15_000, 60_000, 300_000] as const;

// Open Food Facts requires a real contact in the User-Agent. Keep this
// deliberately ASCII-only and bounded: it is configuration metadata, not a
// free-form header value. Whitespace/control characters are rejected rather
// than silently normalized so a malformed service environment fails closed.
const CONTACT_EMAIL_PATTERN = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;

export function validateOpenFoodFactsContactEmail(value: unknown): string | undefined {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_CONTACT_EMAIL_LENGTH) return undefined;
  if (value !== value.trim() || value.includes('\0') || value.includes('\r') || value.includes('\n')) return undefined;
  if (value.includes('..')) return undefined;
  return CONTACT_EMAIL_PATTERN.test(value) ? value : undefined;
}

const FIELDS = [
  'code', 'product_name', 'product_name_de', 'generic_name', 'generic_name_de',
  'brands', 'quantity', 'serving_size', 'countries_tags',
  'nutrition_data_per', 'nutriments', 'data_quality_errors_tags', 'data_quality_warnings_tags',
].join(',');

type RawRecord = Record<string, unknown>;
type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

export type OpenFoodFactsClientOptions = {
  fetch?: FetchLike;
  now?: () => number;
  timeoutMs?: number;
  maxResponseBytes?: number;
  contactEmail?: string;
};

type CacheEntry = { expiresAt: number; value: NutritionBarcodeLookupResponse };

function isRecord(value: unknown): value is RawRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function optionalText(value: unknown, maximum = 240): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximum ? trimmed : undefined;
}

function optionalTags(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const tags = value
    .filter((item): item is string => typeof item === 'string')
    .map(item => item.trim())
    .filter(item => item.length > 0 && item.length <= 120)
    .slice(0, 50);
  return tags.length > 0 ? [...new Set(tags)] : undefined;
}

function optionalMetric(value: unknown, maximum = 100_000): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > maximum) return undefined;
  return value;
}

function macrosFromNutriments(raw: unknown, suffix: '100g' | 'serving'): NutritionMacros | NutritionPer100gMacros | undefined {
  if (!isRecord(raw)) return undefined;
  const isPer100g = suffix === '100g';
  const macroMaximum = isPer100g ? 100 : 2_000;
  const kcalMaximum = isPer100g ? 1_000 : 5_000;
  const values: NutritionMacros = {
    ...(optionalMetric(raw[`energy-kcal_${suffix}`], kcalMaximum) === undefined ? {} : { kcal: optionalMetric(raw[`energy-kcal_${suffix}`], kcalMaximum) }),
    ...(optionalMetric(raw[`proteins_${suffix}`], macroMaximum) === undefined ? {} : { proteinGrams: optionalMetric(raw[`proteins_${suffix}`], macroMaximum) }),
    ...(optionalMetric(raw[`carbohydrates_${suffix}`], macroMaximum) === undefined ? {} : { carbsGrams: optionalMetric(raw[`carbohydrates_${suffix}`], macroMaximum) }),
    ...(optionalMetric(raw[`fat_${suffix}`], macroMaximum) === undefined ? {} : { fatGrams: optionalMetric(raw[`fat_${suffix}`], macroMaximum) }),
  };
  return Object.keys(values).length > 0 ? values : undefined;
}

function hasInvalidNutrientValues(raw: unknown, suffix: '100g' | 'serving'): boolean {
  if (!isRecord(raw)) return false;
  const isPer100g = suffix === '100g';
  const macroMaximum = isPer100g ? 100 : 2_000;
  const kcalMaximum = isPer100g ? 1_000 : 5_000;
  return [
    [`energy-kcal_${suffix}`, kcalMaximum],
    [`proteins_${suffix}`, macroMaximum],
    [`carbohydrates_${suffix}`, macroMaximum],
    [`fat_${suffix}`, macroMaximum],
  ].some(([key, maximum]) => raw[key] !== undefined && optionalMetric(raw[key], maximum as number) === undefined);
}

function nutritionState(
  per100g: NutritionMacros | undefined,
  perServing: NutritionMacros | undefined,
  hasQualityIssue: boolean,
): 'complete' | 'partial' | 'unreliable' | 'unavailable' {
  if (!per100g && !perServing) return 'unavailable';
  if (hasQualityIssue) return 'unreliable';
  const complete = (value: NutritionMacros | undefined) => value !== undefined
    && value.kcal !== undefined
    && value.proteinGrams !== undefined
    && value.carbsGrams !== undefined
    && value.fatGrams !== undefined;
  return complete(per100g) || complete(perServing) ? 'complete' : 'partial';
}

function provenance(barcode: string, fetchedAt: string) {
  const apiURL = `${OPEN_FOOD_FACTS_ORIGIN}/api/${OPEN_FOOD_FACTS_API_VERSION}/product/${barcode}.json`;
  return {
    source: 'openfoodfacts' as const,
    apiVersion: OPEN_FOOD_FACTS_API_VERSION as 'v3.6',
    apiURL,
    productURL: `${OPEN_FOOD_FACTS_ORIGIN}/product/${barcode}`,
    fetchedAt,
    databaseLicense: 'ODbL-1.0' as const,
    contentLicense: 'DbCL-1.0' as const,
    dataQualityWarning: 'Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed.' as const,
    attribution: 'Product data from Open Food Facts. Database: ODbL-1.0; contents: DbCL-1.0. Volunteer-sourced; accuracy and completeness are not guaranteed.',
  };
}

function unavailable(barcode: string, reason: NutritionBarcodeReason, fetchedAt: string, retryAfterSeconds?: number): NutritionBarcodeLookupResponse {
  return NutritionBarcodeLookup.parse({
    schemaVersion: 1,
    state: 'unavailable',
    barcode,
    reason,
    ...(retryAfterSeconds === undefined ? {} : { retryAfterSeconds }),
    provenance: provenance(barcode, fetchedAt),
  });
}

async function readBoundedBody(response: Response, maximumBytes: number): Promise<Buffer> {
  const contentLength = response.headers.get('content-length');
  if (contentLength !== null) {
    const declared = Number(contentLength);
    if (!Number.isSafeInteger(declared) || declared < 0 || declared > maximumBytes) throw new Error('response_too_large');
  }
  if (!response.body) {
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.byteLength > maximumBytes) throw new Error('response_too_large');
    return bytes;
  }
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > maximumBytes) throw new Error('response_too_large');
      chunks.push(Buffer.from(next.value));
    }
  } catch (error) {
    await reader.cancel().catch(() => undefined);
    throw error;
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks);
}

function mapProduct(barcode: string, raw: unknown, fetchedAt: string): NutritionBarcodeLookupResponse {
  if (!isRecord(raw)) return unavailable(barcode, 'invalid_response', fetchedAt);
  const status = raw.status;
  if (status === 'failure' || (status !== 'success' && status !== 'success_with_warnings' && status !== 'success_with_errors')) {
    return unavailable(barcode, 'invalid_response', fetchedAt);
  }
  if (!isRecord(raw.product)) return unavailable(barcode, 'invalid_response', fetchedAt);
  const product = raw.product;
  if (product.code !== undefined
    && (typeof product.code !== 'string' || normalizeNutritionBarcode(product.code) !== barcode)) {
    return unavailable(barcode, 'invalid_response', fetchedAt);
  }
  const nutriments = product.nutriments;
  const per100g = macrosFromNutriments(nutriments, '100g');
  const perServing = macrosFromNutriments(nutriments, 'serving');
  const invalidNutrientValues = hasInvalidNutrientValues(nutriments, '100g') || hasInvalidNutrientValues(nutriments, 'serving');
  const errorTags = optionalTags(product.data_quality_errors_tags) ?? [];
  const warningTags = optionalTags(product.data_quality_warnings_tags) ?? [];
  const topLevelErrors = Array.isArray(raw.errors) && raw.errors.length > 0;
  const topLevelWarnings = Array.isArray(raw.warnings) && raw.warnings.length > 0;
  const hasError = status === 'success_with_errors' || errorTags.length > 0 || topLevelErrors || invalidNutrientValues;
  const hasWarning = status === 'success_with_warnings' || warningTags.length > 0 || topLevelWarnings;
  const hasQualityIssue = hasError || hasWarning;
  const normalizedNutritionState = nutritionState(per100g, perServing, hasQualityIssue);
  const productName = optionalText(product.product_name_de)
    ?? optionalText(product.product_name)
    ?? optionalText(product.generic_name_de)
    ?? optionalText(product.generic_name);
  return NutritionBarcodeLookup.parse({
    schemaVersion: 1,
    state: 'found',
    barcode,
    product: {
      ...(productName === undefined ? {} : { name: productName }),
      ...(optionalText(product.brands) === undefined ? {} : { brand: optionalText(product.brands) }),
      ...(optionalText(product.quantity) === undefined ? {} : { quantity: optionalText(product.quantity) }),
      ...(optionalText(product.serving_size) === undefined ? {} : { servingSize: optionalText(product.serving_size) }),
      ...(optionalTags(product.countries_tags) === undefined ? {} : { countriesTags: optionalTags(product.countries_tags) }),
    },
    nutritionState: normalizedNutritionState,
    ...(per100g === undefined ? {} : { per100g }),
    ...(perServing === undefined ? {} : { perServing }),
    ...(normalizedNutritionState === 'unreliable' ? { qualityFlags: [
      ...(hasError ? ['provider_quality_error' as const] : []),
      ...(hasWarning ? ['provider_quality_warning' as const] : []),
    ] } : {}),
    provenance: provenance(barcode, fetchedAt),
  });
}

export class OpenFoodFactsClient {
  private readonly fetcher: FetchLike;
  private readonly now: () => number;
  private readonly timeoutMs: number;
  private readonly maxResponseBytes: number;
  private readonly contactEmail: string | undefined;
  private readonly cache = new Map<string, CacheEntry>();
  private readonly requestTimes: number[] = [];
  private backoffUntil = 0;
  private backoffLevel = 0;

  constructor(options: OpenFoodFactsClientOptions = {}) {
    this.fetcher = options.fetch ?? fetch;
    this.now = options.now ?? (() => Date.now());
    const requestedTimeout = options.timeoutMs ?? REQUEST_TIMEOUT_MS;
    this.timeoutMs = Number.isFinite(requestedTimeout)
      ? Math.max(1, Math.min(requestedTimeout, REQUEST_TIMEOUT_MS))
      : REQUEST_TIMEOUT_MS;
    const requestedResponseBytes = options.maxResponseBytes ?? MAX_RESPONSE_BYTES;
    this.maxResponseBytes = Number.isFinite(requestedResponseBytes)
      ? Math.max(1_024, Math.min(requestedResponseBytes, MAX_RESPONSE_BYTES))
      : MAX_RESPONSE_BYTES;
    this.contactEmail = validateOpenFoodFactsContactEmail(options.contactEmail);
  }

  async lookup(input: string): Promise<NutritionBarcodeLookupResponse> {
    const barcode = normalizeNutritionBarcode(input);
    if (!barcode) throw new Error('invalid_barcode');
    const now = this.now();
    this.pruneCache(now);
    const cached = this.cache.get(barcode);
    if (cached && cached.expiresAt > now) {
      // Map insertion order is the bounded LRU order.
      this.cache.delete(barcode);
      this.cache.set(barcode, cached);
      return cached.value;
    }
    this.cache.delete(barcode);

    // Open Food Facts requires a real contact in the User-Agent. A deployed
    // composition root must provide it explicitly; never fabricate an address.
    if (!this.contactEmail) {
      const result = unavailable(barcode, 'configuration_unavailable', new Date(now).toISOString());
      this.storeCache(barcode, { expiresAt: now + FAILURE_CACHE_MS, value: result });
      return result;
    }

    if (this.backoffUntil > now) {
      return unavailable(barcode, 'upstream_rate_limited', new Date(now).toISOString(), Math.ceil((this.backoffUntil - now) / 1_000));
    }
    this.pruneRequestTimes(now);
    if (this.requestTimes.length >= REQUESTS_PER_MINUTE) {
      const retryAfter = Math.ceil((this.requestTimes[0]! + RATE_WINDOW_MS - now) / 1_000);
      const result = unavailable(barcode, 'upstream_rate_limited', new Date(now).toISOString(), Math.max(1, retryAfter));
      this.storeCache(barcode, { expiresAt: now + FAILURE_CACHE_MS, value: result });
      return result;
    }
    this.requestTimes.push(now);

    const url = new URL(`${OPEN_FOOD_FACTS_ORIGIN}/api/${OPEN_FOOD_FACTS_API_VERSION}/product/${barcode}.json`);
    url.searchParams.set('product_type', 'food');
    url.searchParams.set('cc', 'de');
    url.searchParams.set('lc', 'de');
    url.searchParams.set('tags_lc', 'de');
    url.searchParams.set('fields', FIELDS);

    let result: NutritionBarcodeLookupResponse;
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), this.timeoutMs);
      let response: Response;
      try {
        response = await this.fetcher(url, {
          method: 'GET',
          headers: {
            accept: 'application/json',
            'accept-language': 'de-DE,de;q=0.9,en;q=0.8',
            'user-agent': `LifeOS/0.2 (${this.contactEmail})`,
          },
          redirect: 'manual',
          signal: controller.signal,
        });
        if (response.status === 404) {
          result = NutritionBarcodeLookup.parse({ schemaVersion: 1, state: 'not_found', barcode, provenance: provenance(barcode, new Date(this.now()).toISOString()) });
          this.backoffLevel = 0;
          this.backoffUntil = 0;
        } else if (response.status === 429 || response.status === 503) {
          const reason: NutritionBarcodeReason = response.status === 429 ? 'upstream_rate_limited' : 'upstream_unavailable';
          result = unavailable(barcode, reason, new Date(this.now()).toISOString(), this.applyBackoff());
        } else if (response.status >= 300 && response.status < 400) {
          result = unavailable(barcode, 'upstream_redirect', new Date(this.now()).toISOString());
        } else if (!response.ok) {
          result = unavailable(barcode, 'upstream_unavailable', new Date(this.now()).toISOString());
        } else {
          const payload = parseStrictJSON(await readBoundedBody(response, this.maxResponseBytes));
          result = mapProduct(barcode, payload, new Date(this.now()).toISOString());
          this.backoffLevel = 0;
          this.backoffUntil = 0;
        }
      } finally {
        // The deadline covers headers and body consumption. Clearing it after
        // fetch() alone lets a slow upstream stream hold the request open.
        clearTimeout(timer);
      }
    } catch (error) {
      const reason: NutritionBarcodeReason = error instanceof Error && error.message === 'response_too_large'
        ? 'upstream_oversized'
        : error instanceof Error && error.name === 'AbortError'
          ? 'upstream_timeout'
          : 'invalid_response';
      result = unavailable(barcode, reason, new Date(this.now()).toISOString());
    }

    const cacheDuration = result.state === 'not_found' ? NEGATIVE_CACHE_MS : result.state === 'found' ? POSITIVE_CACHE_MS : FAILURE_CACHE_MS;
    this.storeCache(barcode, { expiresAt: this.now() + cacheDuration, value: result });
    return result;
  }

  private pruneCache(now: number) {
    for (const [key, value] of this.cache) {
      if (value.expiresAt <= now) this.cache.delete(key);
    }
  }

  private storeCache(key: string, value: CacheEntry) {
    this.cache.delete(key);
    this.cache.set(key, value);
    while (this.cache.size > MAX_CACHE_ENTRIES) {
      const oldest = this.cache.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.cache.delete(oldest);
    }
  }

  private pruneRequestTimes(now: number) {
    while (this.requestTimes[0] !== undefined && this.requestTimes[0]! <= now - RATE_WINDOW_MS) this.requestTimes.shift();
  }

  private applyBackoff(): number {
    const step = BACKOFF_STEPS_MS[Math.min(this.backoffLevel, BACKOFF_STEPS_MS.length - 1)]!;
    this.backoffLevel += 1;
    this.backoffUntil = this.now() + step;
    return Math.ceil(step / 1_000);
  }
}

/**
 * Composition-root factory. The adapter is intentionally inert unless the
 * feature is explicitly enabled and its required contact is valid. In every
 * other case lookup() returns configuration_unavailable before touching fetch.
 */
export function createConfiguredOpenFoodFactsClient(
  environment: Readonly<Record<string, string | undefined>> = process.env,
): OpenFoodFactsClient {
  const contactEmail = environment.OPEN_FOOD_FACTS_ENABLED === 'true'
    ? validateOpenFoodFactsContactEmail(environment.OPEN_FOOD_FACTS_CONTACT_EMAIL)
    : undefined;
  return new OpenFoodFactsClient({ contactEmail });
}

// Kept as a safe compatibility default for callers that import the adapter
// directly. The server composition root creates a fresh configured client so
// tests and service startup cannot inherit stale environment state.
export const openFoodFactsClient = new OpenFoodFactsClient();

export const openFoodFactsLimits = {
  maxResponseBytes: MAX_RESPONSE_BYTES,
  timeoutMs: REQUEST_TIMEOUT_MS,
  requestsPerMinute: REQUESTS_PER_MINUTE,
  maximumCacheEntries: MAX_CACHE_ENTRIES,
} as const;
