import { z } from 'zod';

/**
 * The photo release gate is deliberately a small, offline contract.  It
 * evaluates a pre-collected held-out corpus; it does not call a provider,
 * inspect an image, or change a meal's confirmation state.
 */

const schemaVersion = z.literal(1);
const maximumClockSkewMs = 5_000;
const maximumMeals = 100_000;
const maximumIDs = 100_000;
const maximumVersionLength = 80;
const maximumCalories = 1_000_000;
const maximumMacroGrams = 1_000_000;
const gateThreshold = 0.8;
const tolerance = 0.2;

const safeIDPattern = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})$/;
const safeVersionPattern = /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,79})$/;
const safeID = z.string().trim().min(1).max(128).regex(safeIDPattern, 'unsafe benchmark identifier');
const safeVersion = z.string().trim().min(1).max(maximumVersionLength).regex(safeVersionPattern, 'unsafe benchmark version');

const timestamp = z.string().max(40).datetime({ offset: true });
const observedTimestamp = timestamp.refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'timestamp is too far in the future',
);

// Nutrition values are bounded to two decimal places.  This prevents a
// provider's binary/decimal conversion from presenting precision that the
// reference source cannot support, while still allowing label decimals.
const decimalAtMostTwoPlaces = (value: number) => Math.abs(value * 100 - Math.round(value * 100)) < 1e-8;
const nonnegativeMeasurement = (maximum: number) => z.number()
  .finite()
  .nonnegative()
  .max(maximum)
  .refine(decimalAtMostTwoPlaces, 'nutrition values may have at most two decimal places');
const positiveCalories = nonnegativeMeasurement(maximumCalories).refine(value => value > 0, 'reference calories must be positive');
const estimatedCalories = positiveCalories;
const macroGrams = nonnegativeMeasurement(maximumMacroGrams);

const uniqueIDs = (maximum = maximumIDs) => z.array(safeID).max(maximum).superRefine((values, context) => {
  if (new Set(values).size !== values.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'IDs must be unique' });
  }
});

export const NutritionBenchmarkFoodClass = z.enum([
  'packaged_food',
  'single_ingredient',
  'mixed_dish',
  'varied_lighting_or_angles',
  'restaurant_style',
  'hidden_oil_or_sauce',
  'unknown_portion',
]);
export type NutritionBenchmarkFoodClass = z.infer<typeof NutritionBenchmarkFoodClass>;

export const NutritionBenchmarkReferenceSource = z.enum(['weighed', 'label', 'recipe']);
export type NutritionBenchmarkReferenceSource = z.infer<typeof NutritionBenchmarkReferenceSource>;

export const NutritionBenchmarkMacros = z.object({
  protein: macroGrams,
  carbs: macroGrams,
  fat: macroGrams,
}).strict();
export type NutritionBenchmarkMacros = z.infer<typeof NutritionBenchmarkMacros>;

export const NutritionBenchmarkReference = z.object({
  source: NutritionBenchmarkReferenceSource,
  calories: positiveCalories,
  macros: NutritionBenchmarkMacros,
}).strict();
export type NutritionBenchmarkReference = z.infer<typeof NutritionBenchmarkReference>;

const foodClasses = z.array(NutritionBenchmarkFoodClass).min(1).max(NutritionBenchmarkFoodClass.options.length)
  .superRefine((values, context) => {
    if (new Set(values).size !== values.length) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'food classes must be unique per meal' });
    }
  });

/** One user-representative, reference-labelled meal in the held-out corpus. */
export const NutritionBenchmarkCorpusMeal = z.object({
  mealID: safeID,
  observedAt: observedTimestamp,
  foodClasses,
  reference: NutritionBenchmarkReference,
}).strict();
export type NutritionBenchmarkCorpusMeal = z.infer<typeof NutritionBenchmarkCorpusMeal>;

const requiredFoodClasses = new Set<NutritionBenchmarkFoodClass>(NutritionBenchmarkFoodClass.options);

/**
 * A versioned, held-out corpus.  Evaluation IDs are derived from `meals` so
 * they cannot drift from the records whose reference calories are evaluated.
 * Training and tuning IDs are retained as an explicit exclusion list.
 */
export const NutritionBenchmarkCorpus = z.object({
  schemaVersion,
  corpusID: safeID,
  corpusVersion: safeVersion,
  split: z.literal('held_out'),
  userRepresentative: z.literal(true),
  trainingMealIDs: uniqueIDs(),
  tuningMealIDs: uniqueIDs(),
  meals: z.array(NutritionBenchmarkCorpusMeal).min(1).max(maximumMeals),
}).strict().superRefine((value, context) => {
  const evaluationIDs = new Set<string>();
  const coveredClasses = new Set<NutritionBenchmarkFoodClass>();
  value.meals.forEach((meal, index) => {
    if (evaluationIDs.has(meal.mealID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['meals', index, 'mealID'], message: 'duplicate evaluation meal ID' });
    }
    evaluationIDs.add(meal.mealID);
    meal.foodClasses.forEach(foodClass => coveredClasses.add(foodClass));
  });

  value.trainingMealIDs.forEach((mealID, index) => {
    if (evaluationIDs.has(mealID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['trainingMealIDs', index], message: 'training meal ID overlaps evaluation IDs' });
    }
  });
  value.tuningMealIDs.forEach((mealID, index) => {
    if (evaluationIDs.has(mealID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tuningMealIDs', index], message: 'tuning meal ID overlaps evaluation IDs' });
    }
  });
  const trainingAndTuning = new Set(value.trainingMealIDs);
  value.tuningMealIDs.forEach((mealID, index) => {
    if (trainingAndTuning.has(mealID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tuningMealIDs', index], message: 'training and tuning IDs must be disjoint' });
    }
  });

  for (const foodClass of requiredFoodClasses) {
    if (!coveredClasses.has(foodClass)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['meals'], message: `held-out corpus is missing food class ${foodClass}` });
    }
  }
});
export type NutritionBenchmarkCorpus = z.infer<typeof NutritionBenchmarkCorpus>;

export const NutritionBenchmarkResultState = z.enum(['estimated', 'needs_confirmation', 'failed']);
export type NutritionBenchmarkResultState = z.infer<typeof NutritionBenchmarkResultState>;

/** One model result paired to exactly one corpus meal. */
export const NutritionBenchmarkMealResult = z.object({
  resultID: safeID,
  mealID: safeID,
  observedAt: observedTimestamp,
  state: NutritionBenchmarkResultState,
  estimatedTotalCalories: estimatedCalories.optional(),
  estimatedMacros: NutritionBenchmarkMacros.optional(),
}).strict().superRefine((value, context) => {
  if (value.state === 'failed') {
    if (value.estimatedTotalCalories !== undefined || value.estimatedMacros !== undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['state'], message: 'failed result cannot carry an estimate' });
    }
  } else if (value.estimatedTotalCalories === undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimatedTotalCalories'], message: 'non-failed result requires a calorie estimate' });
  } else if (value.estimatedMacros === undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimatedMacros'], message: 'non-failed result requires protein, carbs, and fat estimates' });
  }
  if (value.estimatedMacros !== undefined && value.estimatedTotalCalories === undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimatedMacros'], message: 'macro estimate requires a calorie estimate' });
  }
});
export type NutritionBenchmarkMealResult = z.infer<typeof NutritionBenchmarkMealResult>;

/** A model/policy run over one exact held-out corpus version. */
export const NutritionBenchmarkResults = z.object({
  schemaVersion,
  benchmarkID: safeID,
  corpusID: safeID,
  corpusVersion: safeVersion,
  modelVersion: safeVersion,
  policyVersion: safeVersion,
  split: z.literal('held_out'),
  observedAt: observedTimestamp,
  results: z.array(NutritionBenchmarkMealResult).min(1).max(maximumMeals),
}).strict().superRefine((value, context) => {
  const resultIDs = new Set<string>();
  const mealIDs = new Set<string>();
  value.results.forEach((result, index) => {
    if (resultIDs.has(result.resultID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['results', index, 'resultID'], message: 'duplicate benchmark result ID' });
    }
    resultIDs.add(result.resultID);
    if (mealIDs.has(result.mealID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['results', index, 'mealID'], message: 'duplicate result meal ID' });
    }
    mealIDs.add(result.mealID);
  });
});
export type NutritionBenchmarkResults = z.infer<typeof NutritionBenchmarkResults>;

const nutritionMetricShape = {
  count: z.number().int().nonnegative().max(maximumMeals),
  evaluatedCount: z.number().int().nonnegative().max(maximumMeals),
  within20Count: z.number().int().nonnegative().max(maximumMeals),
  within20Fraction: z.number().finite().min(0).max(1),
  mape: z.number().finite().nonnegative(),
  medianAPE: z.number().finite().nonnegative(),
  p95APE: z.number().finite().nonnegative(),
  failureOrNeedsConfirmationRate: z.number().finite().min(0).max(1),
};

function validateMetricCounts(value: z.infer<z.ZodObject<typeof nutritionMetricShape>>, context: z.RefinementCtx) {
  if (value.evaluatedCount > value.count) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['evaluatedCount'], message: 'evaluated count cannot exceed count' });
  }
  if (value.within20Count > value.evaluatedCount || value.within20Count > value.count) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['within20Count'], message: 'within-gate count exceeds evaluated count' });
  }
  const expectedFraction = value.count === 0 ? 0 : roundMetric(value.within20Count / value.count);
  if (Math.abs(value.within20Fraction - expectedFraction) > 1e-6) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['within20Fraction'], message: 'within-gate fraction does not match the counts' });
  }
}

export const NutritionBenchmarkMetric = z.object(nutritionMetricShape).strict().superRefine((value, context) => {
  validateMetricCounts(value, context);
});
export type NutritionBenchmarkMetric = z.infer<typeof NutritionBenchmarkMetric>;

export const NutritionBenchmarkMacroMetric = z.object({
  ...nutritionMetricShape,
  meanAbsoluteErrorGrams: z.number().finite().nonnegative(),
  percentageEvaluatedCount: z.number().int().nonnegative().max(maximumMeals),
}).strict().superRefine((value, context) => {
  validateMetricCounts(value, context);
  if (value.percentageEvaluatedCount > value.evaluatedCount) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['percentageEvaluatedCount'], message: 'percentage count cannot exceed evaluated count' });
  }
});
export type NutritionBenchmarkMacroMetric = z.infer<typeof NutritionBenchmarkMacroMetric>;

export const NutritionBenchmarkReleaseAction = z.enum([
  'assistive_preview_or_disabled',
  'assistive_preview_requires_confirmation',
]);
export type NutritionBenchmarkReleaseAction = z.infer<typeof NutritionBenchmarkReleaseAction>;

export const NutritionBenchmarkReport = z.object({
  schemaVersion,
  benchmarkID: safeID,
  corpusID: safeID,
  corpusVersion: safeVersion,
  modelVersion: safeVersion,
  policyVersion: safeVersion,
  split: z.literal('held_out'),
  observedAt: observedTimestamp,
  count: z.number().int().positive().max(maximumMeals),
  evaluatedCount: z.number().int().nonnegative().max(maximumMeals),
  within20Count: z.number().int().nonnegative().max(maximumMeals),
  within20Fraction: z.number().finite().min(0).max(1),
  gateThreshold: z.literal(gateThreshold),
  gatePassed: z.boolean(),
  mape: z.number().finite().nonnegative(),
  medianAPE: z.number().finite().nonnegative(),
  p95APE: z.number().finite().nonnegative(),
  failureOrNeedsConfirmationRate: z.number().finite().min(0).max(1),
  foodClassMetrics: z.object({
    packaged_food: NutritionBenchmarkMetric,
    single_ingredient: NutritionBenchmarkMetric,
    mixed_dish: NutritionBenchmarkMetric,
    varied_lighting_or_angles: NutritionBenchmarkMetric,
    restaurant_style: NutritionBenchmarkMetric,
    hidden_oil_or_sauce: NutritionBenchmarkMetric,
    unknown_portion: NutritionBenchmarkMetric,
  }).strict(),
  macroMetrics: z.object({
    protein: NutritionBenchmarkMacroMetric,
    carbs: NutritionBenchmarkMacroMetric,
    fat: NutritionBenchmarkMacroMetric,
  }).strict(),
  releaseAction: NutritionBenchmarkReleaseAction,
  requiresUserConfirmation: z.literal(true),
  autoFinalize: z.literal(false),
}).strict().superRefine((value, context) => {
  if (value.evaluatedCount > value.count || value.within20Count > value.evaluatedCount) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['count'], message: 'report counts are inconsistent' });
  }
  if (value.gatePassed !== (value.within20Fraction >= gateThreshold)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['gatePassed'], message: 'gate result does not match the 80% threshold' });
  }
  const expectedFraction = roundMetric(value.within20Count / value.count);
  if (Math.abs(value.within20Fraction - expectedFraction) > 1e-6) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['within20Fraction'], message: 'within-gate fraction does not match the counts' });
  }
  const expectedAction = value.gatePassed ? 'assistive_preview_requires_confirmation' : 'assistive_preview_or_disabled';
  if (value.releaseAction !== expectedAction) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['releaseAction'], message: 'release action does not match the gate result' });
  }
});
export type NutritionBenchmarkReport = z.infer<typeof NutritionBenchmarkReport>;

type ErrorSample = { absolutePercentageError: number; withinGate: boolean };

function roundMetric(value: number): number {
  // Six decimal places is enough for an audit report and avoids leaking
  // floating-point implementation noise into a versioned contract.
  return Math.round((value + Number.EPSILON) * 1_000_000) / 1_000_000;
}

function percentileNearestRank(sortedValues: number[], percentile: number): number {
  if (sortedValues.length === 0) return 0;
  const rank = Math.max(1, Math.ceil(percentile * sortedValues.length));
  return sortedValues[rank - 1] ?? sortedValues[sortedValues.length - 1]!;
}

function median(sortedValues: number[]): number {
  if (sortedValues.length === 0) return 0;
  const middle = Math.floor(sortedValues.length / 2);
  return sortedValues.length % 2 === 0
    ? (sortedValues[middle - 1]! + sortedValues[middle]!) / 2
    : sortedValues[middle]!;
}

function emptyMetric(count: number, failureOrNeedsConfirmationRate: number): NutritionBenchmarkMetric {
  return {
    count,
    evaluatedCount: 0,
    within20Count: 0,
    within20Fraction: 0,
    mape: 0,
    medianAPE: 0,
    p95APE: 0,
    failureOrNeedsConfirmationRate: roundMetric(failureOrNeedsConfirmationRate),
  };
}

function metricFor(count: number, failures: number, samples: ErrorSample[]): NutritionBenchmarkMetric {
  if (samples.length === 0) return emptyMetric(count, count === 0 ? 0 : failures / count);
  const errors = samples.map(sample => sample.absolutePercentageError).sort((a, b) => a - b);
  const within20Count = samples.filter(sample => sample.withinGate).length;
  return {
    count,
    evaluatedCount: samples.length,
    within20Count,
    within20Fraction: roundMetric(count === 0 ? 0 : within20Count / count),
    mape: roundMetric(errors.reduce((sum, error) => sum + error, 0) / errors.length),
    medianAPE: roundMetric(median(errors)),
    p95APE: roundMetric(percentileNearestRank(errors, 0.95)),
    failureOrNeedsConfirmationRate: roundMetric(count === 0 ? 0 : failures / count),
  };
}

type MacroSample = ErrorSample & { absoluteErrorGrams: number; hasPercentageError: boolean };

function macroMetricFor(count: number, failures: number, samples: MacroSample[]): NutritionBenchmarkMacroMetric {
  const baseSamples = samples.map(sample => ({
    absolutePercentageError: sample.absolutePercentageError,
    withinGate: sample.withinGate,
  }));
  const base = metricFor(count, failures, baseSamples);
  const percentageErrors = samples
    .filter(sample => sample.hasPercentageError)
    .map(sample => sample.absolutePercentageError)
    .sort((a, b) => a - b);
  return {
    ...base,
    meanAbsoluteErrorGrams: roundMetric(samples.length === 0 ? 0 : samples.reduce((sum, sample) => sum + sample.absoluteErrorGrams, 0) / samples.length),
    percentageEvaluatedCount: percentageErrors.length,
    mape: roundMetric(percentageErrors.length === 0 ? 0 : percentageErrors.reduce((sum, error) => sum + error, 0) / percentageErrors.length),
    medianAPE: roundMetric(median(percentageErrors)),
    p95APE: roundMetric(percentileNearestRank(percentageErrors, 0.95)),
  };
}

/**
 * Parses and evaluates one held-out run.  The function is pure with respect
 * to its inputs: it returns a report and never mutates either input or a
 * confirmed meal.  Failed gates intentionally select a fail-safe assistive
 * mode; even a passing gate still requires explicit user confirmation.
 */
export function evaluateNutritionBenchmark(
  corpusInput: unknown,
  resultsInput: unknown,
): NutritionBenchmarkReport {
  const corpus = NutritionBenchmarkCorpus.parse(corpusInput);
  const results = NutritionBenchmarkResults.parse(resultsInput);
  if (results.corpusID !== corpus.corpusID || results.corpusVersion !== corpus.corpusVersion || results.split !== corpus.split) {
    throw new Error('benchmark results do not match the held-out corpus identity/version/split');
  }
  if (results.results.length !== corpus.meals.length) {
    throw new Error('exactly one result is required for every evaluation meal');
  }

  const corpusByMealID = new Map(corpus.meals.map(meal => [meal.mealID, meal]));
  const resultByMealID = new Map(results.results.map(result => [result.mealID, result]));
  if (resultByMealID.size !== corpusByMealID.size || [...corpusByMealID.keys()].some(mealID => !resultByMealID.has(mealID))) {
    throw new Error('benchmark results must cover exactly the corpus evaluation meal IDs');
  }
  for (const meal of corpus.meals) {
    const result = resultByMealID.get(meal.mealID)!;
    if (Date.parse(result.observedAt) < Date.parse(meal.observedAt)) {
      throw new Error('benchmark result observation predates its corpus meal');
    }
    if (Date.parse(result.observedAt) > Date.parse(results.observedAt)) {
      throw new Error('benchmark result observation postdates the benchmark run');
    }
  }

  const allSamples: ErrorSample[] = [];
  let failures = 0;
  let within20Count = 0;
  const classSamples = new Map<NutritionBenchmarkFoodClass, ErrorSample[]>();
  const classFailures = new Map<NutritionBenchmarkFoodClass, number>();
  for (const foodClass of NutritionBenchmarkFoodClass.options) {
    classSamples.set(foodClass, []);
    classFailures.set(foodClass, 0);
  }

  const macroNames = ['protein', 'carbs', 'fat'] as const;
  const macroSamples = new Map<(typeof macroNames)[number], MacroSample[]>();
  for (const macro of macroNames) macroSamples.set(macro, []);

  for (const meal of corpus.meals) {
    const result = resultByMealID.get(meal.mealID)!;
    const failedOrNeedsConfirmation = result.state === 'failed' || result.state === 'needs_confirmation';
    if (failedOrNeedsConfirmation) failures += 1;

    let sample: ErrorSample | undefined;
    if (result.state !== 'failed' && result.estimatedTotalCalories !== undefined) {
      const absolutePercentageError = Math.abs(result.estimatedTotalCalories - meal.reference.calories) / meal.reference.calories;
      sample = { absolutePercentageError, withinGate: absolutePercentageError <= tolerance + Number.EPSILON };
      allSamples.push(sample);
      if (sample.withinGate) within20Count += 1;
    }
    for (const foodClass of meal.foodClasses) {
      if (sample) classSamples.get(foodClass)!.push(sample);
      if (failedOrNeedsConfirmation) classFailures.set(foodClass, classFailures.get(foodClass)! + 1);
    }

    if (result.state !== 'failed' && result.estimatedMacros !== undefined) {
      for (const macro of macroNames) {
        const referenceValue = meal.reference.macros[macro];
        const estimatedValue = result.estimatedMacros[macro];
        const absoluteErrorGrams = Math.abs(estimatedValue - referenceValue);
        const hasPercentageError = referenceValue > 0;
        const absolutePercentageError = hasPercentageError ? absoluteErrorGrams / referenceValue : 0;
        macroSamples.get(macro)!.push({
          absoluteErrorGrams,
          hasPercentageError,
          absolutePercentageError,
          withinGate: hasPercentageError && absolutePercentageError <= tolerance + Number.EPSILON,
        });
      }
    }
  }

  const sortedErrors = allSamples.map(sample => sample.absolutePercentageError).sort((a, b) => a - b);
  const within20Fraction = within20Count / corpus.meals.length;
  const gatePassed = within20Fraction >= gateThreshold;
  const foodClassMetrics = Object.fromEntries(NutritionBenchmarkFoodClass.options.map(foodClass => [
    foodClass,
    metricFor(
      corpus.meals.filter(meal => meal.foodClasses.includes(foodClass)).length,
      classFailures.get(foodClass)!,
      classSamples.get(foodClass)!,
    ),
  ])) as NutritionBenchmarkReport['foodClassMetrics'];

  const macroMetrics = Object.fromEntries(macroNames.map(macro => [
    macro,
    macroMetricFor(corpus.meals.length, failures, macroSamples.get(macro)!),
  ])) as NutritionBenchmarkReport['macroMetrics'];

  return NutritionBenchmarkReport.parse({
    schemaVersion: 1,
    benchmarkID: results.benchmarkID,
    corpusID: corpus.corpusID,
    corpusVersion: corpus.corpusVersion,
    modelVersion: results.modelVersion,
    policyVersion: results.policyVersion,
    split: 'held_out',
    observedAt: results.observedAt,
    count: corpus.meals.length,
    evaluatedCount: allSamples.length,
    within20Count,
    within20Fraction: roundMetric(within20Fraction),
    gateThreshold,
    gatePassed,
    mape: roundMetric(sortedErrors.length === 0 ? 0 : sortedErrors.reduce((sum, error) => sum + error, 0) / sortedErrors.length),
    medianAPE: roundMetric(median(sortedErrors)),
    p95APE: roundMetric(percentileNearestRank(sortedErrors, 0.95)),
    failureOrNeedsConfirmationRate: roundMetric(failures / corpus.meals.length),
    foodClassMetrics,
    macroMetrics,
    releaseAction: gatePassed ? 'assistive_preview_requires_confirmation' : 'assistive_preview_or_disabled',
    requiresUserConfirmation: true,
    autoFinalize: false,
  });
}

export const evaluateNutritionPhotoReleaseGate = evaluateNutritionBenchmark;
