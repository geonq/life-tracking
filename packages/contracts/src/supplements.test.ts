import { describe, expect, it } from 'vitest';
import {
  InventoryEvent,
  SupplementOccurrence,
  SupplementOccurrenceActionRequest,
  SupplementOccurrenceActionResponse,
  SupplementCorrection,
  SupplementNutrientFact,
  SupplementPlan,
  SupplementSnapshot,
} from './supplements.js';

const now = new Date().toISOString();
const later = new Date(Date.now() + 60_000).toISOString();

const plan = {
  id: 'magnesium-200', name: 'Magnesium', brand: 'User-entered product', productIdentifier: 'batch-a',
  form: 'capsule', strength: '200 mg', servingUnit: 'capsule', userDose: { amount: 1, unit: 'capsule' }, inventoryUnitsPerDose: 1,
  schedule: {
    weekdays: [1, 3, 5], localTime: '11:30', timeZoneIdentifier: 'Europe/Berlin', timingNote: 'Before lunch',
    startDate: '2026-08-01', endDate: '2026-12-31', pauseRanges: [{ startDate: '2026-09-01', endDate: '2026-09-03' }],
    notificationPreference: 'product_and_timing', calendarOverlayEnabled: true,
  },
  source: 'manual', productLabelNote: { text: 'Take with food.', sourceDate: '2026-07-30' }, notes: 'User-entered plan',
  stockUnits: 18, reorderThreshold: 5, expectedLeadTimeDays: 7, expiryDate: later, supplier: 'Local pharmacy',
  reminderEnabled: true, lockScreenRedacted: true, revision: 3, updatedAt: now,
} as const;

const occurrence = {
  id: 'magnesium-200-20260811-1130', planID: plan.id, scheduledFor: now,
  state: 'planned' as const, revision: 3, updatedAt: now,
};

const takenOccurrence = { ...occurrence, state: 'taken' as const, actedAt: now };
const inventoryRefill = {
  id: 'magnesium-refill-1', planID: plan.id, kind: 'refill' as const, delta: 30, stockAfter: 48, occurredAt: now,
  costCents: 1299, batch: 'batch-b', expiry: later, source: 'Local pharmacy',
  forecastAssumptions: { dosesPerScheduledDay: 1, scheduledDaysPerWeek: 3, inventoryUnitsPerDose: 1, asOf: now },
};
const inventoryTaken = {
  id: 'magnesium-taken-1', planID: plan.id, kind: 'taken_decrement' as const, delta: -1, stockAfter: 17,
  occurredAt: now, occurrenceID: takenOccurrence.id,
};
const correction = {
  id: 'correction-1', entityKind: 'plan' as const, entityID: plan.id, field: 'stockUnits', oldValue: 18,
  newValue: 20, actorID: 'iphone-17', correctedAt: now, reason: 'Counted the opened bottle again',
};

describe('supplement contracts', () => {
  it('accepts a bounded, strict plan and snapshot', () => {
    expect(SupplementPlan.parse(plan).id).toBe(plan.id);
    expect(SupplementSnapshot.parse({
      schemaVersion: 1, generatedAt: now, revision: 3, plans: [plan], occurrences: [occurrence],
      corrections: [], inventoryEvents: [],
    }).plans).toHaveLength(1);
  });

  it('rejects unknown fields, unsafe identifiers, duplicate weekdays, malformed times and path-like zones', () => {
    expect(() => SupplementPlan.parse({ ...plan, extra: true })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, form: 'gummy' })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, id: '../secret' })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, weekdays: [1, 1] } })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, localTime: '9:30' } })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, timeZoneIdentifier: 'Europe/../Berlin' } })).toThrow();
    expect(SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, timingNote: 'Before lunch' } }).schedule.timingNote).toBe('Before lunch');
    expect(() => SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, timingNote: 'x'.repeat(121) } })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, notificationPreference: 'private' } })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, pauseRanges: [{ startDate: '2026-09-01', endDate: '2026-09-04' }, { startDate: '2026-09-04', endDate: '2026-09-05' }] } })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, schedule: { ...plan.schedule, endDate: '2026-07-31' } })).toThrow();
  });

  it('rejects future actual timestamps beyond five seconds and out-of-bound inventory', () => {
    expect(() => SupplementPlan.parse({ ...plan, updatedAt: new Date(Date.now() + 60_000).toISOString() })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, stockUnits: 1_000_000_001 })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, inventoryUnitsPerDose: 0 })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, expectedLeadTimeDays: 366 })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, userDose: { amount: 1.2345, unit: 'capsule' } })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, userDose: { amount: 0, unit: 'capsule' } })).toThrow();
    expect(SupplementPlan.parse({ ...plan, userDose: { amount: 1.234, unit: 'capsule' } }).userDose?.amount).toBe(1.234);
  });

  it('keeps exact nutrient amounts per unit separate from the label daily-dose basis', () => {
    const calcium = {
      nutrientID: 'calcium', name: 'Calcium', amountPerUnit: 400, unit: 'mg', labelBasisUnits: 2, nrvPercent: 100,
    } as const;
    expect(SupplementNutrientFact.parse(calcium).amountPerUnit).toBe(400);
    expect(SupplementPlan.parse({ ...plan, nutrientFacts: [calcium] }).nutrientFacts?.[0].labelBasisUnits).toBe(2);
    expect(() => SupplementNutrientFact.parse({ ...calcium, unit: 'serving' })).toThrow();
    expect(() => SupplementNutrientFact.parse({ ...calcium, amountPerUnit: 0 })).toThrow();
    expect(() => SupplementNutrientFact.parse({ ...calcium, nutrientID: 'vitamin/../calcium' })).toThrow();
    expect(() => SupplementPlan.parse({ ...plan, nutrientFacts: [calcium, calcium] })).toThrow();
  });

  it('enforces occurrence state timestamps', () => {
    expect(SupplementOccurrence.parse(occurrence).state).toBe('planned');
    expect(() => SupplementOccurrence.parse({ ...occurrence, state: 'taken' })).toThrow();
    expect(() => SupplementOccurrence.parse({ ...occurrence, state: 'planned', actedAt: now })).toThrow();
    expect(SupplementOccurrence.parse({ ...occurrence, state: 'missed' }).state).toBe('missed');
    expect(() => SupplementOccurrence.parse({ ...occurrence, state: 'missed', actedAt: now })).toThrow();
    expect(() => SupplementOccurrence.parse({ ...occurrence, state: 'snoozed', actedAt: now, snoozedUntil: now })).toThrow();
    expect(SupplementOccurrence.parse({ ...occurrence, state: 'snoozed', actedAt: now, snoozedUntil: later }).state).toBe('snoozed');
  });

  it('rejects duplicate records and orphan occurrences in a snapshot', () => {
    const base = { schemaVersion: 1, generatedAt: now, revision: 3, plans: [plan], occurrences: [occurrence], corrections: [], inventoryEvents: [] };
    expect(() => SupplementSnapshot.parse({ ...base, plans: [plan, plan] })).toThrow();
    expect(() => SupplementSnapshot.parse({ ...base, occurrences: [{ ...occurrence, planID: 'missing-plan' }] })).toThrow();
    expect(() => SupplementSnapshot.parse({ ...base, occurrences: [occurrence, occurrence] })).toThrow();
  });

  it('accepts and validates refill and Taken inventory events', () => {
    const parsed = SupplementSnapshot.parse({
      schemaVersion: 1, generatedAt: now, revision: 3, plans: [plan], occurrences: [takenOccurrence],
      corrections: [], inventoryEvents: [inventoryRefill, inventoryTaken],
    });
    expect(parsed.inventoryEvents).toHaveLength(2);
    expect(() => InventoryEvent.parse({ ...inventoryTaken, delta: 1 })).toThrow();
    expect(() => InventoryEvent.parse({ ...inventoryRefill, delta: -1 })).toThrow();
    expect(() => InventoryEvent.parse({ ...inventoryRefill, delta: 0 })).toThrow();
    expect(() => InventoryEvent.parse({ ...inventoryTaken, occurrenceID: undefined })).toThrow();
    expect(() => InventoryEvent.parse({ ...inventoryTaken, costCents: 100 })).toThrow();
    expect(() => InventoryEvent.parse({ ...inventoryRefill, occurrenceID: takenOccurrence.id })).toThrow();
  });

  it('accepts corrections and rejects equal values, bad links, and unknown fields', () => {
    const base = { schemaVersion: 1, generatedAt: now, revision: 3, plans: [plan], occurrences: [takenOccurrence], corrections: [correction], inventoryEvents: [inventoryTaken] };
    expect(SupplementCorrection.parse(correction).entityKind).toBe('plan');
    expect(SupplementSnapshot.parse({ ...base, corrections: [correction, { ...correction, id: 'correction-2', entityKind: 'occurrence', entityID: takenOccurrence.id }] }).corrections).toHaveLength(2);
    expect(SupplementSnapshot.parse({ ...base, corrections: [{ ...correction, id: 'correction-2', entityKind: 'inventory', entityID: inventoryTaken.id }] }).corrections).toHaveLength(1);
    expect(() => SupplementCorrection.parse({ ...correction, oldValue: 'same', newValue: 'same' })).toThrow();
    expect(() => SupplementCorrection.parse({ ...correction, extra: true })).toThrow();
    expect(() => SupplementSnapshot.parse({ ...base, corrections: [{ ...correction, entityID: 'missing' }] })).toThrow();
    expect(() => SupplementSnapshot.parse({ ...base, inventoryEvents: [inventoryTaken, inventoryTaken] })).toThrow();
    expect(() => SupplementSnapshot.parse({ ...base, corrections: [correction, correction] })).toThrow();
  });

  it('requires a valid snooze action and keeps non-snooze actions free of snoozeUntil', () => {
    const base = { actionID: 'action-1', occurrenceID: occurrence.id, planID: plan.id, occurredAt: now, baseRevision: 3, sourceDeviceID: 'iphone-17' };
    expect(SupplementOccurrenceActionRequest.parse({ ...base, action: 'taken' }).action).toBe('taken');
    expect(SupplementOccurrenceActionRequest.parse({ ...base, action: 'snooze', snoozeUntil: later }).snoozeUntil).toBe(later);
    expect(() => SupplementOccurrenceActionRequest.parse({ ...base, action: 'snooze' })).toThrow();
    expect(() => SupplementOccurrenceActionRequest.parse({ ...base, action: 'skip', snoozeUntil: later })).toThrow();
    expect(() => SupplementOccurrenceActionRequest.parse({ ...base, action: 'snooze', snoozeUntil: now })).toThrow();
  });

  it('models inventory as a negative delta only for the first Taken action', () => {
    const taken = { ...occurrence, state: 'taken' as const, actedAt: now };
    expect(SupplementOccurrenceActionResponse.parse({ occurrence: taken, inventoryDelta: -1, idempotent: false, serverRevision: 4 }).inventoryDelta).toBe(-1);
    expect(SupplementOccurrenceActionResponse.parse({ occurrence: taken, inventoryDelta: 0, idempotent: false, serverRevision: 4 }).inventoryDelta).toBe(0);
    expect(SupplementOccurrenceActionResponse.parse({ occurrence: taken, inventoryDelta: 0, idempotent: true, serverRevision: 4 }).idempotent).toBe(true);
    const skipped = { ...occurrence, state: 'skipped' as const, actedAt: now };
    expect(SupplementOccurrenceActionResponse.parse({ occurrence: skipped, inventoryDelta: 0, idempotent: false, serverRevision: 4 }).inventoryDelta).toBe(0);
    expect(() => SupplementOccurrenceActionResponse.parse({ occurrence: skipped, inventoryDelta: -1, idempotent: false, serverRevision: 4 })).toThrow();
    expect(() => SupplementOccurrenceActionResponse.parse({ occurrence: taken, inventoryDelta: -1, idempotent: true, serverRevision: 4 })).toThrow();
  });
});
