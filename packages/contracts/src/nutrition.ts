import { z } from 'zod';

/**
 * Versioned boundary for the optional photo-to-food flow.
 *
 * A photo result is an assistive proposal only.  The confirmation contract is
 * the only branch that can carry a final structured meal, and it remains
 * linked to the request and proposal that the user reviewed.
 */

const schemaVersion = z.literal(1);
const maximumClockSkewMs = 5_000;
const maximumPhotoBytes = 20 * 1024 * 1024;
const maximumPhotoCount = 3;
const maximumImageDimension = 12_000;
const maximumImagePixels = 40_000_000;
const maximumItems = 40;
const maximumText = 1_000;
const maximumAmount = 1_000_000;
const maximumQuantity = 100_000;
const maximumUncertaintyNotes = 8;

const safeIDPattern = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})$/;
const secretLikePattern = /(?:api[_ -]?key|access[_ -]?token|auth(?:orization)?|bearer|client[_ -]?secret|password|private[_ -]?key|refresh[_ -]?token|secret|token\s*[:=]|sk-[A-Za-z0-9]|AIza[A-Za-z0-9_-]{20,})/i;
const prohibitedAdvicePattern = /\b(?:diagnos(?:is|e|tic)|allerg(?:y|ic|ies)|medical|medication|prescri(?:be|ption)|supplement(?:s)?|disease|treatment)\b/i;

const boundedText = (maximum = maximumText) => z.string().trim().min(1).max(maximum);
const secretFreeText = (maximum = maximumText) => boundedText(maximum).refine(
  value => !secretLikePattern.test(value),
  'text must not contain credentials or authentication material',
);
const foodText = (maximum = maximumText) => secretFreeText(maximum).refine(
  value => !prohibitedAdvicePattern.test(value),
  'food inference text must not contain medical, allergy, diagnosis, or supplement advice',
);

const safeOpaqueID = z.string().min(1).max(128).regex(safeIDPattern, 'unsafe opaque identifier');
export const FoodRequestID = safeOpaqueID;
export type FoodRequestID = z.infer<typeof FoodRequestID>;
export const FoodMealID = safeOpaqueID;
export type FoodMealID = z.infer<typeof FoodMealID>;

const timestamp = z.string().max(40).datetime({ offset: true });
const observedTimestamp = timestamp.refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'timestamp is too far in the future',
);

/** IANA-like slash-separated timezone names; dot segments are path syntax. */
const ianaTimezone = z.string().min(1).max(64)
  .regex(/^(?:UTC|[A-Za-z][A-Za-z0-9+_-]{0,31}(?:\/[A-Za-z0-9+_-]{1,31})+)$/, 'invalid IANA timezone')
  .refine(value => !value.split('/').some(segment => segment === '.' || segment === '..'), 'timezone contains a dot segment');
export const FoodClientTimeZone = ianaTimezone;
export type FoodClientTimeZone = z.infer<typeof FoodClientTimeZone>;

const decimalAtMostTwoPlaces = (value: number) => Math.abs(value * 100 - Math.round(value * 100)) < 1e-8;
const boundedAmount = z.number().finite().nonnegative().max(maximumAmount).refine(decimalAtMostTwoPlaces, 'amount may have at most two decimal places');
const positiveAmount = z.number().finite().positive().max(maximumAmount).refine(decimalAtMostTwoPlaces, 'amount may have at most two decimal places');
const boundedQuantity = z.number().finite().positive().max(maximumQuantity).refine(decimalAtMostTwoPlaces, 'quantity may have at most two decimal places');

const imageMimeType = z.enum(['image/jpeg', 'image/png', 'image/heic', 'image/webp']);
const sha256 = z.string().regex(/^[A-Fa-f0-9]{64}$/, 'expected a SHA-256 digest');
const base64 = z.string().min(4).max(Math.ceil(maximumPhotoBytes / 3) * 4)
  .refine(isCanonicalBase64, 'expected canonical base64 without a data URI or whitespace');

function isCanonicalBase64(value: string): boolean {
  if (value.length % 4 !== 0) return false;
  const firstPadding = value.indexOf('=');
  const contentEnd = firstPadding === -1 ? value.length : firstPadding;
  if (firstPadding !== -1 && firstPadding < value.length - 2) return false;
  for (let index = 0; index < contentEnd; index += 1) {
    const code = value.charCodeAt(index);
    const isUpper = code >= 65 && code <= 90;
    const isLower = code >= 97 && code <= 122;
    const isDigit = code >= 48 && code <= 57;
    if (!isUpper && !isLower && !isDigit && value[index] !== '+' && value[index] !== '/') return false;
  }
  if (firstPadding === -1) return true;
  const paddingCount = value.length - firstPadding;
  if (paddingCount !== 1 && paddingCount !== 2) return false;
  return value.slice(firstPadding) === '='.repeat(paddingCount);
}

function decodedBase64ByteLength(value: string): number {
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  return (value.length / 4) * 3 - padding;
}

export const FoodPhotoImageDescriptor = z.object({
  imageID: safeOpaqueID,
  mimeType: imageMimeType,
  byteLength: z.number().int().min(1).max(maximumPhotoBytes),
  width: z.number().int().min(1).max(maximumImageDimension),
  height: z.number().int().min(1).max(maximumImageDimension),
  sanitized: z.literal(true),
  inlineDataBase64: base64,
  sha256,
}).strict().superRefine((value, context) => {
  if (value.width * value.height > maximumImagePixels) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['width'], message: 'image dimensions exceed the decompression-bomb pixel bound' });
  }
  if (decodedBase64ByteLength(value.inlineDataBase64) !== value.byteLength) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['inlineDataBase64'], message: 'inline image bytes do not match byteLength' });
  }
});
export type FoodPhotoImageDescriptor = z.infer<typeof FoodPhotoImageDescriptor>;

/** Context is intentionally user-entered and contains no provider fields. */
export const FoodPhotoUserContext = z.object({
  plateDiameterMm: z.number().finite().min(50).max(1_000).refine(decimalAtMostTwoPlaces, 'plate diameter may have at most two decimal places').optional(),
  knownReference: secretFreeText(200).optional(),
  portionWeightGrams: boundedAmount.optional(),
  packageLabelContext: secretFreeText(1_000).optional(),
  note: secretFreeText(500).optional(),
}).strict();
export type FoodPhotoUserContext = z.infer<typeof FoodPhotoUserContext>;

export const FoodPhotoManifest = z.object({
  schemaVersion,
  mealID: FoodMealID,
  requestID: FoodRequestID,
  capturedAt: observedTimestamp,
  clientTimeZone: ianaTimezone,
  inferenceConsent: z.literal(true),
  images: z.array(FoodPhotoImageDescriptor).min(1).max(maximumPhotoCount),
  userContext: FoodPhotoUserContext.optional(),
}).strict().superRefine((value, context) => {
  const imageIDs = new Set<string>();
  let totalBytes = 0;
  value.images.forEach((image, index) => {
    if (imageIDs.has(image.imageID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['images', index, 'imageID'], message: 'duplicate image id' });
    }
    imageIDs.add(image.imageID);
    totalBytes += image.byteLength;
  });
  if (totalBytes > maximumPhotoBytes) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['images'], message: 'combined photo payload exceeds 20 MiB' });
  }
});
export type FoodPhotoManifest = z.infer<typeof FoodPhotoManifest>;

export const FoodEstimateConfidence = z.enum(['low', 'medium', 'high']);
export type FoodEstimateConfidence = z.infer<typeof FoodEstimateConfidence>;

export const FoodEstimateFlag = z.enum([
  'needs_confirmation',
  'mixed_dish',
  'unknown_portion',
  'hidden_oil',
  'low_confidence',
  'wide_interval',
]);
export type FoodEstimateFlag = z.infer<typeof FoodEstimateFlag>;

/** A bounded interval. The point estimate must be inside the interval. */
export const FoodEstimateRange = z.object({
  estimate: boundedAmount,
  min: boundedAmount,
  max: boundedAmount,
}).strict().superRefine((value, context) => {
  if (value.min > value.max) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['max'], message: 'range maximum must be at least its minimum' });
  }
  if (value.estimate < value.min || value.estimate > value.max) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimate'], message: 'estimate must be contained by its range' });
  }
});
export type FoodEstimateRange = z.infer<typeof FoodEstimateRange>;

const foodUnit = z.enum(['g', 'kg', 'ml', 'l', 'oz', 'lb', 'serving', 'portion', 'piece', 'slice', 'cup', 'tbsp', 'tsp']);

export const FoodEstimateAlternative = foodText(160);
export type FoodEstimateAlternative = z.infer<typeof FoodEstimateAlternative>;

export const FoodEstimateItem = z.object({
  itemID: safeOpaqueID,
  enteredLabel: foodText(160).optional(),
  estimatedLabel: foodText(160),
  labelSource: z.enum(['recognized', 'assumed']),
  quantity: boundedQuantity,
  unit: foodUnit,
  grams: FoodEstimateRange,
  calories: FoodEstimateRange,
  protein: FoodEstimateRange,
  carbs: FoodEstimateRange,
  fat: FoodEstimateRange,
  fiber: FoodEstimateRange.optional(),
  confidence: FoodEstimateConfidence,
  uncertaintyNotes: z.array(foodText(240)).max(maximumUncertaintyNotes).optional(),
  alternatives: z.array(FoodEstimateAlternative).max(5).optional(),
  flags: z.array(FoodEstimateFlag).max(FoodEstimateFlag.options.length).optional(),
}).strict().superRefine((value, context) => {
  if (value.grams.estimate <= 0 || value.grams.max <= 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['grams'], message: 'food item grams must be positive' });
  }
  if (value.flags && new Set(value.flags).size !== value.flags.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['flags'], message: 'duplicate item flags' });
  }
  if (value.alternatives && new Set(value.alternatives).size !== value.alternatives.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['alternatives'], message: 'duplicate item alternatives' });
  }
  validateNutrientSemantics(value, context, ['items']);
});
export type FoodEstimateItem = z.infer<typeof FoodEstimateItem>;

export const FoodEstimateTotals = z.object({
  grams: FoodEstimateRange,
  calories: FoodEstimateRange,
  protein: FoodEstimateRange,
  carbs: FoodEstimateRange,
  fat: FoodEstimateRange,
  fiber: FoodEstimateRange.optional(),
}).strict();
export type FoodEstimateTotals = z.infer<typeof FoodEstimateTotals>;

export const FoodEstimateProvenance = z.object({
  provider: secretFreeText(120),
  modelIdentifier: secretFreeText(160),
  modelVersion: secretFreeText(80),
  policyVersion: secretFreeText(80),
  requestTimestamp: observedTimestamp,
  sanitizedImageHashes: z.array(z.object({
    imageID: safeOpaqueID,
    sha256,
  }).strict()).min(1).max(maximumPhotoCount),
}).strict().superRefine((value, context) => {
  const ids = new Set<string>();
  value.sanitizedImageHashes.forEach((hash, index) => {
    if (ids.has(hash.imageID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['sanitizedImageHashes', index, 'imageID'], message: 'duplicate image hash reference' });
    }
    ids.add(hash.imageID);
  });
});
export type FoodEstimateProvenance = z.infer<typeof FoodEstimateProvenance>;

const rangeTolerance = 0.05;
const sumTolerance = (sum: number) => Math.max(rangeTolerance, Math.abs(sum) * 0.005);

type NutrientValue = {
  grams: FoodEstimateRange;
  calories: FoodEstimateRange;
  protein: FoodEstimateRange;
  carbs: FoodEstimateRange;
  fat: FoodEstimateRange;
  fiber?: FoodEstimateRange;
};

function validateNutrientSemantics(value: NutrientValue, context: z.RefinementCtx, path: (string | number)[]) {
  const macroMass = value.protein.max + value.carbs.max + value.fat.max;
  if (macroMass > value.grams.max + 5) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: [...path, 'grams'], message: 'estimated macros exceed plausible food mass' });
  }
  if (value.calories.max > value.grams.max * 9 + 100) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: [...path, 'calories'], message: 'calories exceed the configured food energy bound' });
  }
  if (!macroEnergyIsPlausible(value.calories.estimate, value.protein.estimate, value.carbs.estimate, value.fat.estimate)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: [...path, 'calories'], message: 'calories are implausible for the estimated macros' });
  }
}

function validateTotals(value: FoodEstimateProposalValue, context: z.RefinementCtx) {
  const dimensions = ['grams', 'calories', 'protein', 'carbs', 'fat'] as const;
  for (const dimension of dimensions) {
    const total = value.totals[dimension];
    const items = value.items.map(item => item[dimension]);
    const sumEstimate = items.reduce((sum, range) => sum + range.estimate, 0);
    const sumMin = items.reduce((sum, range) => sum + range.min, 0);
    const sumMax = items.reduce((sum, range) => sum + range.max, 0);
    const tolerance = sumTolerance(sumEstimate);
    if (Math.abs(total.estimate - sumEstimate) > tolerance
      || total.min > sumMin + tolerance
      || total.max < sumMax - tolerance) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['totals', dimension], message: 'total range is inconsistent with item ranges' });
    }
  }

  if (value.totals.fiber !== undefined) {
    if (value.items.some(item => item.fiber === undefined)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['totals', 'fiber'], message: 'fiber total requires fiber on every item' });
    } else {
      const items = value.items.map(item => item.fiber!);
      const sumEstimate = items.reduce((sum, range) => sum + range.estimate, 0);
      const sumMin = items.reduce((sum, range) => sum + range.min, 0);
      const sumMax = items.reduce((sum, range) => sum + range.max, 0);
      const tolerance = sumTolerance(sumEstimate);
      const total = value.totals.fiber;
      if (Math.abs(total.estimate - sumEstimate) > tolerance || total.min > sumMin + tolerance || total.max < sumMax - tolerance) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['totals', 'fiber'], message: 'fiber total range is inconsistent with item ranges' });
      }
    }
  }

  validateNutrientSemantics(value.totals, context, ['totals']);
}

function macroEnergyIsPlausible(calories: number, protein: number, carbs: number, fat: number) {
  const macroEnergy = protein * 4 + carbs * 4 + fat * 9;
  // Fiber, alcohol, labels, and rounding can move values. This bounded window
  // allows those effects while rejecting disconnected provider claims.
  return calories >= Math.max(0, macroEnergy * 0.25 - 100)
    && calories <= macroEnergy * 2.5 + 100;
}

type FoodEstimateProposalValue = {
  items: FoodEstimateItem[];
  totals: FoodEstimateTotals;
};

export const FoodEstimateProposal = z.object({
  schemaVersion,
  mealID: FoodMealID,
  proposalID: safeOpaqueID,
  requestID: FoodRequestID,
  state: z.literal('needs_confirmation'),
  generatedAt: observedTimestamp,
  provenance: FoodEstimateProvenance,
  items: z.array(FoodEstimateItem).min(1).max(maximumItems),
  totals: FoodEstimateTotals,
  flags: z.array(FoodEstimateFlag).min(1).max(FoodEstimateFlag.options.length),
  uncertaintyNotes: z.array(foodText(240)).max(maximumUncertaintyNotes).optional(),
}).strict().superRefine((value, context) => {
  if (!value.flags.includes('needs_confirmation')) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['flags'], message: 'proposal must carry the needs_confirmation flag' });
  }
  if (new Set(value.flags).size !== value.flags.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['flags'], message: 'duplicate proposal flags' });
  }
  if (Date.parse(value.generatedAt) < Date.parse(value.provenance.requestTimestamp)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['generatedAt'], message: 'proposal generation timestamp predates inference request' });
  }
  if (value.items.some(item => item.confidence === 'low') && !value.flags.includes('low_confidence')) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['flags'], message: 'low-confidence items require the low_confidence flag' });
  }

  const itemIDs = new Set<string>();
  value.items.forEach((item, index) => {
    if (itemIDs.has(item.itemID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['items', index, 'itemID'], message: 'duplicate item id' });
    }
    itemIDs.add(item.itemID);
  });
  validateTotals(value, context);
});
export type FoodEstimateProposal = z.infer<typeof FoodEstimateProposal>;

/**
 * Binds a server proposal to the exact sanitized images described by the
 * request. A proposal from another request, meal, timestamp, or image set is
 * not reusable.
 */
export function validateFoodEstimateProposalAgainstManifest(
  proposalInput: unknown,
  manifestInput: unknown,
): FoodEstimateProposal {
  const proposal = FoodEstimateProposal.parse(proposalInput);
  const manifest = FoodPhotoManifest.parse(manifestInput);
  if (proposal.requestID !== manifest.requestID || proposal.mealID !== manifest.mealID) {
    throw new Error('proposal request/meal id does not match photo manifest');
  }
  if (Date.parse(proposal.provenance.requestTimestamp) < Date.parse(manifest.capturedAt)) {
    throw new Error('proposal request timestamp predates photo capture');
  }
  if (Date.parse(proposal.generatedAt) < Date.parse(proposal.provenance.requestTimestamp)) {
    throw new Error('proposal generation timestamp predates inference request');
  }

  const hashes = proposal.provenance.sanitizedImageHashes;
  if (hashes.length !== manifest.images.length || hashes.some((hash, index) => {
    const image = manifest.images[index];
    return image === undefined || hash.imageID !== image.imageID || hash.sha256.toLowerCase() !== image.sha256.toLowerCase();
  })) {
    throw new Error('proposal image hashes do not reference exactly the manifest images');
  }
  return proposal;
}

const confirmedAmount = boundedAmount;
const ConfirmedFoodItem = z.object({
  itemID: safeOpaqueID,
  label: foodText(160),
  quantity: boundedQuantity,
  unit: foodUnit,
  grams: positiveAmount,
  calories: confirmedAmount,
  protein: confirmedAmount,
  carbs: confirmedAmount,
  fat: confirmedAmount,
  fiber: confirmedAmount.optional(),
}).strict().superRefine((value, context) => {
  validateNutrientSemantics({
    grams: { estimate: value.grams, min: value.grams, max: value.grams },
    calories: { estimate: value.calories, min: value.calories, max: value.calories },
    protein: { estimate: value.protein, min: value.protein, max: value.protein },
    carbs: { estimate: value.carbs, min: value.carbs, max: value.carbs },
    fat: { estimate: value.fat, min: value.fat, max: value.fat },
    ...(value.fiber === undefined ? {} : { fiber: { estimate: value.fiber, min: value.fiber, max: value.fiber } }),
  }, context, []);
});
export const FoodConfirmedItem = ConfirmedFoodItem;
export type FoodConfirmedItem = z.infer<typeof FoodConfirmedItem>;

const ConfirmedFoodTotals = z.object({
  grams: positiveAmount,
  calories: confirmedAmount,
  protein: confirmedAmount,
  carbs: confirmedAmount,
  fat: confirmedAmount,
  fiber: confirmedAmount.optional(),
}).strict();
export const FoodConfirmedTotals = ConfirmedFoodTotals;
export type FoodConfirmedTotals = z.infer<typeof FoodConfirmedTotals>;

const confirmedMealFields = {
  mealName: foodText(200).optional(),
  mealAt: observedTimestamp,
  items: z.array(ConfirmedFoodItem).min(1).max(maximumItems),
  totals: ConfirmedFoodTotals,
  confirmedAt: observedTimestamp,
};

function validateConfirmedMeal(value: { items: FoodConfirmedItem[]; totals: FoodConfirmedTotals }, context: z.RefinementCtx) {
  const ids = new Set<string>();
  value.items.forEach((item, index) => {
    if (ids.has(item.itemID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['items', index, 'itemID'], message: 'duplicate confirmed item id' });
    }
    ids.add(item.itemID);
  });
  const sum = (key: 'grams' | 'calories' | 'protein' | 'carbs' | 'fat' | 'fiber') => value.items.reduce((total, item) => total + (item[key] ?? 0), 0);
  for (const key of ['grams', 'calories', 'protein', 'carbs', 'fat'] as const) {
    if (Math.abs(value.totals[key] - sum(key)) > sumTolerance(sum(key))) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['totals', key], message: 'confirmed total does not match confirmed items' });
    }
  }
  if (value.totals.fiber !== undefined && value.items.some(item => item.fiber === undefined)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['totals', 'fiber'], message: 'fiber total requires fiber on every confirmed item' });
  } else if (value.totals.fiber !== undefined && Math.abs(value.totals.fiber - sum('fiber')) > sumTolerance(sum('fiber'))) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['totals', 'fiber'], message: 'confirmed fiber total does not match items' });
  }
  validateNutrientSemantics({
    grams: { estimate: value.totals.grams, min: value.totals.grams, max: value.totals.grams },
    calories: { estimate: value.totals.calories, min: value.totals.calories, max: value.totals.calories },
    protein: { estimate: value.totals.protein, min: value.totals.protein, max: value.totals.protein },
    carbs: { estimate: value.totals.carbs, min: value.totals.carbs, max: value.totals.carbs },
    fat: { estimate: value.totals.fat, min: value.totals.fat, max: value.totals.fat },
  }, context, ['totals']);
}

const rejectConfirmation = z.object({
  schemaVersion,
  mealID: FoodMealID,
  requestID: FoodRequestID,
  proposalID: safeOpaqueID,
  action: z.literal('reject'),
  rejectedAt: observedTimestamp,
  reason: secretFreeText(500).optional(),
}).strict();

const confirmConfirmation = z.object({
  schemaVersion,
  mealID: FoodMealID,
  requestID: FoodRequestID,
  proposalID: safeOpaqueID,
  action: z.literal('confirm'),
  ...confirmedMealFields,
}).strict();

const editAndConfirmConfirmation = z.object({
  schemaVersion,
  mealID: FoodMealID,
  requestID: FoodRequestID,
  proposalID: safeOpaqueID,
  action: z.literal('edit_and_confirm'),
  ...confirmedMealFields,
  correctionNotes: foodText(500),
}).strict();

export const FoodConfirmationRequest = z.discriminatedUnion('action', [
  rejectConfirmation,
  confirmConfirmation,
  editAndConfirmConfirmation,
]).superRefine((value, context) => {
  if (value.action === 'confirm' || value.action === 'edit_and_confirm') {
    validateConfirmedMeal(value, context);
  }
});
export type FoodConfirmationRequest = z.infer<typeof FoodConfirmationRequest>;

/** Verifies confirmation lineage without restricting legitimate user edits. */
export function validateFoodConfirmationAgainstProposal(
  confirmationInput: unknown,
  proposalInput: unknown,
): FoodConfirmationRequest {
  const confirmation = FoodConfirmationRequest.parse(confirmationInput);
  const proposal = FoodEstimateProposal.parse(proposalInput);
  if (confirmation.requestID !== proposal.requestID || confirmation.proposalID !== proposal.proposalID || confirmation.mealID !== proposal.mealID) {
    throw new Error('confirmation does not reference the reviewed proposal lineage');
  }
  const eventAt = confirmation.action === 'reject' ? confirmation.rejectedAt : confirmation.confirmedAt;
  if (Date.parse(eventAt) < Date.parse(proposal.generatedAt)) {
    throw new Error('confirmation event predates the proposal');
  }
  return confirmation;
}
