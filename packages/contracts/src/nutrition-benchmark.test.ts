import { describe, expect, it } from 'vitest';
import {
  NutritionBenchmarkCorpus,
  NutritionBenchmarkMealResult,
  NutritionBenchmarkMetric,
  evaluateNutritionBenchmark,
} from './nutrition-benchmark.js';

const now = new Date().toISOString();
const earlier = new Date(Date.now() - 60_000).toISOString();
const foodClasses = [
  'packaged_food',
  'single_ingredient',
  'mixed_dish',
  'varied_lighting_or_angles',
  'restaurant_style',
  'hidden_oil_or_sauce',
  'unknown_portion',
] as const;

const corpus = {
  schemaVersion: 1,
  corpusID: 'nutrition-corpus',
  corpusVersion: 'corpus-2026-08',
  split: 'held_out' as const,
  userRepresentative: true as const,
  trainingMealIDs: ['train-1'],
  tuningMealIDs: ['tune-1'],
  meals: Array.from({ length: 10 }, (_, index) => ({
    mealID: `eval-${index + 1}`,
    observedAt: now,
    foodClasses: [foodClasses[index % foodClasses.length]],
    reference: {
      source: (index % 3 === 0 ? 'weighed' : index % 3 === 1 ? 'label' : 'recipe') as 'weighed' | 'label' | 'recipe',
      calories: 100,
      macros: { protein: 20, carbs: 10, fat: 5 },
    },
  })),
};

const results = (calorieFractions: number[] = Array(10).fill(1), states: Array<'estimated' | 'needs_confirmation' | 'failed'> = Array(10).fill('estimated')) => ({
  schemaVersion: 1,
  benchmarkID: 'run-1',
  corpusID: corpus.corpusID,
  corpusVersion: corpus.corpusVersion,
  modelVersion: 'model-2026-08',
  policyVersion: 'policy-1',
  split: 'held_out' as const,
  observedAt: now,
  results: corpus.meals.map((meal, index) => ({
    resultID: `result-${index + 1}`,
    mealID: meal.mealID,
    observedAt: now,
    state: states[index],
    ...(states[index] === 'failed' ? {} : {
      estimatedTotalCalories: 100 * calorieFractions[index],
      estimatedMacros: { protein: 20, carbs: 10, fat: 5 },
    }),
  })),
});

describe('nutrition photo benchmark release gate', () => {
  it('accepts a strict held-out representative corpus and reports the passing gate', () => {
    expect(NutritionBenchmarkCorpus.parse(corpus).split).toBe('held_out');
    const report = evaluateNutritionBenchmark(corpus, results());
    expect(report).toMatchObject({
      count: 10,
      evaluatedCount: 10,
      within20Count: 10,
      within20Fraction: 1,
      gatePassed: true,
      releaseAction: 'assistive_preview_requires_confirmation',
      requiresUserConfirmation: true,
      autoFinalize: false,
    });
  });

  it('includes the exact ±20% boundary and exact 80% gate boundary', () => {
    const atTwenty = Array(10).fill(1);
    atTwenty[0] = 1.2;
    const exactBoundary = evaluateNutritionBenchmark(corpus, results(atTwenty));
    expect(exactBoundary.within20Count).toBe(10);
    expect(exactBoundary.gatePassed).toBe(true);

    const atEighty = Array(10).fill(1);
    atEighty[8] = 1.21;
    atEighty[9] = 1.21;
    const eighty = evaluateNutritionBenchmark(corpus, results(atEighty));
    expect(eighty.within20Count).toBe(8);
    expect(eighty.within20Fraction).toBe(0.8);
    expect(eighty.gatePassed).toBe(true);

    const below = [...atEighty];
    below[7] = 1.21;
    const failed = evaluateNutritionBenchmark(corpus, results(below));
    expect(failed.within20Count).toBe(7);
    expect(failed.gatePassed).toBe(false);
    expect(failed.releaseAction).toBe('assistive_preview_or_disabled');
    expect(failed.autoFinalize).toBe(false);
  });

  it('sorts errors before median and nearest-rank p95 calculations', () => {
    const fractions = [1, 1.01, 1.02, 1.03, 1.04, 1.05, 1.06, 1.07, 1.08, 1.19];
    const report = evaluateNutritionBenchmark(corpus, results(fractions));
    expect(report.medianAPE).toBe(0.045);
    expect(report.p95APE).toBe(0.19);
  });

  it('counts a needs-confirmation estimate toward calorie accuracy while reporting its separate rate', () => {
    const states = Array(10).fill('estimated') as Array<'estimated' | 'needs_confirmation' | 'failed'>;
    states[0] = 'needs_confirmation';
    states[1] = 'failed';
    const report = evaluateNutritionBenchmark(corpus, results(Array(10).fill(1), states));
    expect(report.failureOrNeedsConfirmationRate).toBe(0.2);
    expect(report.within20Fraction).toBe(0.9);
    expect(report.releaseAction).toBe('assistive_preview_requires_confirmation');
    expect(report.requiresUserConfirmation).toBe(true);
    expect(report.autoFinalize).toBe(false);
  });

  it('requires coverage, disjoint training/tuning IDs, and unique meal/result IDs', () => {
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, meals: corpus.meals.slice(1, 7) })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, trainingMealIDs: ['eval-1'] })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, tuningMealIDs: ['train-1'] })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, meals: [corpus.meals[0], corpus.meals[0], ...corpus.meals.slice(2)] })).toThrow();
    expect(() => evaluateNutritionBenchmark(corpus, {
      ...results(), results: [results().results[0], results().results[0], ...results().results.slice(2)],
    })).toThrow();
  });

  it('rejects unknown fields, unsafe precision, zero/invalid reference calories, and future timestamps', () => {
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, unexpected: true })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, meals: [{ ...corpus.meals[0], unexpected: true }, ...corpus.meals.slice(1)] })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, meals: [{ ...corpus.meals[0], reference: { ...corpus.meals[0].reference, calories: 0 } }, ...corpus.meals.slice(1)] })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, meals: [{ ...corpus.meals[0], reference: { ...corpus.meals[0].reference, calories: -1 } }, ...corpus.meals.slice(1)] })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, meals: [{ ...corpus.meals[0], reference: { ...corpus.meals[0].reference, calories: 100.123 } }, ...corpus.meals.slice(1)] })).toThrow();
    expect(() => NutritionBenchmarkCorpus.parse({ ...corpus, meals: [{ ...corpus.meals[0], observedAt: new Date(Date.now() + 60_000).toISOString() }, ...corpus.meals.slice(1)] })).toThrow();
    expect(() => NutritionBenchmarkMealResult.parse({
      resultID: 'result-1', mealID: 'eval-1', observedAt: now, state: 'estimated', estimatedTotalCalories: 100.123,
    })).toThrow();
    expect(() => NutritionBenchmarkMealResult.parse({
      resultID: 'result-1', mealID: 'eval-1', observedAt: now, state: 'estimated', estimatedTotalCalories: 100,
    })).toThrow();
    expect(() => NutritionBenchmarkMetric.parse({
      count: 10, evaluatedCount: 10, within20Count: 8, within20Fraction: 0.7,
      mape: 0, medianAPE: 0, p95APE: 0, failureOrNeedsConfirmationRate: 0,
    })).toThrow();
  });

  it('requires exact result identity/version and one result per evaluation meal', () => {
    expect(() => evaluateNutritionBenchmark(corpus, { ...results(), corpusVersion: 'other-corpus' })).toThrow();
    expect(() => evaluateNutritionBenchmark(corpus, { ...results(), results: results().results.slice(0, 9) })).toThrow();
    expect(() => evaluateNutritionBenchmark(corpus, {
      ...results(), results: results().results.map((result, index) => index === 0 ? { ...result, mealID: 'not-in-corpus' } : result),
    })).toThrow();
  });

  it('keeps corpus/result observations in chronological order', () => {
    const mealObservedAfterResult = { ...corpus, meals: [{ ...corpus.meals[0], observedAt: now }, ...corpus.meals.slice(1)] };
    const resultBeforeMeal = { ...results(), results: results().results.map((result, index) => index === 0 ? { ...result, observedAt: earlier } : result) };
    expect(() => evaluateNutritionBenchmark(mealObservedAfterResult, resultBeforeMeal)).toThrow();

    const runBeforeResult = { ...results(), observedAt: earlier };
    expect(() => evaluateNutritionBenchmark(corpus, runBeforeResult)).toThrow();
  });
});
