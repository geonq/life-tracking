import { z } from 'zod';

/**
 * Read-only, server-normalized Open Food Facts barcode contract.
 *
 * Values are deliberately represented as independent optional fields.  A
 * missing provider value is not converted to zero and no kcal/kJ or serving
 * conversion is performed at this boundary.
 */

const schemaVersion = z.literal(1);
const timestamp = z.string().max(40).datetime({ offset: true });
const maximumBarcodeText = 32;
const maximumText = 240;
const maximumServingKcal = 5_000;
const maximumServingMacroGrams = 2_000;
const maximumPer100gKcal = 1_000;
const maximumPer100gMacroGrams = 100;
const maximumTags = 50;

export const NutritionBarcodeState = z.enum(['found', 'not_found', 'unavailable']);
export type NutritionBarcodeState = z.infer<typeof NutritionBarcodeState>;

export const NutritionBarcodeReason = z.enum([
  'upstream_timeout',
  'upstream_rate_limited',
  'upstream_unavailable',
  'upstream_redirect',
  'upstream_oversized',
  'invalid_response',
  'configuration_unavailable',
]);
export type NutritionBarcodeReason = z.infer<typeof NutritionBarcodeReason>;

export const NutritionDataState = z.enum(['complete', 'partial', 'unreliable', 'unavailable']);
export type NutritionDataState = z.infer<typeof NutritionDataState>;
export const NutritionQualityFlag = z.enum(['provider_quality_error', 'provider_quality_warning']);
export type NutritionQualityFlag = z.infer<typeof NutritionQualityFlag>;

export const NutritionBarcodeCode = z.string().regex(/^\d{8}$|^\d{13}$/, 'expected canonical EAN-8 or EAN-13');

const servingKcal = z.number().finite().nonnegative().max(maximumServingKcal);
const servingMacroGrams = z.number().finite().nonnegative().max(maximumServingMacroGrams);
const per100gKcal = z.number().finite().nonnegative().max(maximumPer100gKcal);
const per100gMacroGrams = z.number().finite().nonnegative().max(maximumPer100gMacroGrams);
const macros = {
  kcal: servingKcal.optional(),
  proteinGrams: servingMacroGrams.optional(),
  carbsGrams: servingMacroGrams.optional(),
  fatGrams: servingMacroGrams.optional(),
};
const hasAnyMacro = (value: { kcal?: number; proteinGrams?: number; carbsGrams?: number; fatGrams?: number }) => Object.values(value).some(item => item !== undefined);
export const NutritionMacros = z.object(macros).strict().refine(hasAnyMacro, 'nutrition values must contain at least one valid metric');
export type NutritionMacros = z.infer<typeof NutritionMacros>;

export const NutritionPer100gMacros = z.object({
  kcal: per100gKcal.optional(),
  proteinGrams: per100gMacroGrams.optional(),
  carbsGrams: per100gMacroGrams.optional(),
  fatGrams: per100gMacroGrams.optional(),
}).strict().refine(hasAnyMacro, 'per-100g nutrition must contain at least one valid metric');
export type NutritionPer100gMacros = z.infer<typeof NutritionPer100gMacros>;

export const NutritionServingMacros = NutritionMacros;
export type NutritionServingMacros = z.infer<typeof NutritionServingMacros>;

export const NutritionBarcodeProduct = z.object({
  name: z.string().trim().min(1).max(maximumText).optional(),
  brand: z.string().trim().min(1).max(maximumText).optional(),
  quantity: z.string().trim().min(1).max(maximumText).optional(),
  servingSize: z.string().trim().min(1).max(maximumText).optional(),
  countriesTags: z.array(z.string().trim().min(1).max(120)).max(maximumTags).optional(),
}).strict();
export type NutritionBarcodeProduct = z.infer<typeof NutritionBarcodeProduct>;

export const NutritionBarcodeProvenance = z.object({
  source: z.literal('openfoodfacts'),
  apiVersion: z.literal('v3.6'),
  apiURL: z.string().url().max(2_048),
  productURL: z.string().url().max(2_048).optional(),
  fetchedAt: timestamp,
  databaseLicense: z.literal('ODbL-1.0'),
  contentLicense: z.literal('DbCL-1.0'),
  attribution: z.string().trim().min(1).max(500),
  dataQualityWarning: z.literal('Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed.'),
}).strict();
export type NutritionBarcodeProvenance = z.infer<typeof NutritionBarcodeProvenance>;

const commonFields = {
  schemaVersion,
  barcode: NutritionBarcodeCode,
  provenance: NutritionBarcodeProvenance,
} as const;

export const NutritionBarcodeFound = z.object({
  ...commonFields,
  state: z.literal('found'),
  product: NutritionBarcodeProduct,
  nutritionState: NutritionDataState,
  per100g: NutritionPer100gMacros.optional(),
  perServing: NutritionServingMacros.optional(),
  qualityFlags: z.array(NutritionQualityFlag).min(1).max(NutritionQualityFlag.options.length)
    .refine(value => new Set(value).size === value.length, 'quality flags must be unique').optional(),
}).strict().superRefine((value, context) => {
  const hasNutrition = value.per100g !== undefined || value.perServing !== undefined;
  const isComplete = (basis: NutritionMacros | undefined) => basis !== undefined
    && basis.kcal !== undefined
    && basis.proteinGrams !== undefined
    && basis.carbsGrams !== undefined
    && basis.fatGrams !== undefined;
  const hasCompleteBasis = isComplete(value.per100g) || isComplete(value.perServing);
  const qualityFlags = value.qualityFlags ?? [];
  if (value.nutritionState === 'unavailable' && (hasNutrition || qualityFlags.length > 0)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['nutritionState'], message: 'unavailable nutrition cannot contain values' });
  }
  if (value.nutritionState !== 'unavailable' && !hasNutrition) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['nutritionState'], message: 'available nutrition requires values' });
  }
  if (value.nutritionState === 'complete' && !hasCompleteBasis) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['nutritionState'], message: 'complete nutrition requires all four metrics for one basis' });
  }
  if (value.nutritionState === 'partial' && hasCompleteBasis) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['nutritionState'], message: 'partial nutrition cannot contain a complete basis' });
  }
  if (value.nutritionState === 'unreliable' && qualityFlags.length === 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['qualityFlags'], message: 'unreliable nutrition requires a provider quality flag' });
  }
  if (value.nutritionState !== 'unreliable' && qualityFlags.length > 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['qualityFlags'], message: 'provider quality flags require unreliable nutrition state' });
  }
});
export type NutritionBarcodeFound = z.infer<typeof NutritionBarcodeFound>;

export const NutritionBarcodeNotFound = z.object({
  ...commonFields,
  state: z.literal('not_found'),
}).strict();
export type NutritionBarcodeNotFound = z.infer<typeof NutritionBarcodeNotFound>;

export const NutritionBarcodeUnavailable = z.object({
  ...commonFields,
  state: z.literal('unavailable'),
  reason: NutritionBarcodeReason,
  retryAfterSeconds: z.number().int().min(0).max(3_600).optional(),
}).strict();
export type NutritionBarcodeUnavailable = z.infer<typeof NutritionBarcodeUnavailable>;

// The found branch has cross-field refinements (ZodEffects), so a regular
// union is required here; callers still receive the same literal `state`
// discriminator after parsing.
export const NutritionBarcodeLookup = z.union([
  NutritionBarcodeFound,
  NutritionBarcodeNotFound,
  NutritionBarcodeUnavailable,
]);
export type NutritionBarcodeLookup = z.infer<typeof NutritionBarcodeLookup>;
export const NutritionBarcodeLookupResponse = NutritionBarcodeLookup;
export type NutritionBarcodeLookupResponse = NutritionBarcodeLookup;

/**
 * Normalize user/scanner input to the canonical EAN representation used by
 * the server. UPC-A is checksum-validated and represented as EAN-13 with a
 * leading zero; no other barcode family is accepted.
 */
export function normalizeNutritionBarcode(input: string): string | undefined {
  if (typeof input !== 'string' || input.length > maximumBarcodeText) return undefined;
  const trimmed = input.trim();
  if (!trimmed || !/^[0-9 \t-]+$/.test(trimmed)) return undefined;
  const digits = trimmed.replace(/[ \t-]/g, '');
  if (![8, 12, 13].includes(digits.length)) return undefined;
  if (!hasValidChecksum(digits)) return undefined;
  return digits.length === 12 ? `0${digits}` : digits;
}

function hasValidChecksum(digits: string): boolean {
  const checkDigit = Number(digits.at(-1));
  const data = digits.slice(0, -1);
  let sum = 0;
  for (let index = data.length - 1, weight = 3; index >= 0; index -= 1, weight = weight === 3 ? 1 : 3) {
    sum += Number(data[index]) * weight;
  }
  return (10 - (sum % 10)) % 10 === checkDigit;
}

export const NutritionBarcodeContractConstants = {
  schemaVersion: 1,
  maximumBarcodeText,
  maximumServingKcal,
  maximumServingMacroGrams,
  maximumPer100gKcal,
  maximumPer100gMacroGrams,
  maximumTags,
} as const;
