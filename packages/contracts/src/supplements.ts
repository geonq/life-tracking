import { z } from 'zod';

/**
 * Supplement data is user-entered health data.  These bounds are deliberately
 * small enough to keep a malformed client from turning the sync endpoint into
 * an unbounded document store.
 */
const maxClockSkewMs = 5_000;
const maxRevision = Number.MAX_SAFE_INTEGER;
const maxInventoryUnits = 1_000_000_000;

const boundedText = (maximum: number) => z.string().trim().min(1).max(maximum);
const safeIDPattern = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})$/;

/** Opaque identifiers may be persisted and echoed, but never contain paths. */
export const SupplementID = z.string().min(1).max(128).regex(safeIDPattern, 'unsafe supplement identifier');
export type SupplementID = z.infer<typeof SupplementID>;

const timestamp = z.string().max(40).datetime({ offset: true });
const observedTimestamp = timestamp.refine(
  value => Date.parse(value) <= Date.now() + maxClockSkewMs,
  'timestamp is too far in the future',
);

const localTime = z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/, 'local time must be HH:mm');

const dateOnly = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'date must be YYYY-MM-DD')
  .refine(value => {
    const [year, month, day] = value.split('-').map(Number);
    const parsed = new Date(Date.UTC(year, month - 1, day));
    return parsed.getUTCFullYear() === year && parsed.getUTCMonth() === month - 1 && parsed.getUTCDate() === day;
  }, 'invalid calendar date');

// IANA names are slash-separated labels.  Dot segments are intentionally
// rejected even though some platforms accept them: a timezone is not a path.
const ianaTimezone = z.string().min(1).max(64)
  .regex(/^(?:UTC|[A-Za-z][A-Za-z0-9+_-]{0,31}(?:\/[A-Za-z0-9+_-]{1,31})+)$/, 'invalid IANA timezone')
  .refine(value => !value.split('/').some(segment => segment === '.' || segment === '..'), 'timezone contains a dot segment');

const revision = z.number().finite().int().nonnegative().max(maxRevision);
const inventoryUnits = z.number().finite().int().nonnegative().max(maxInventoryUnits);

export const SupplementSchedule = z.object({
  weekdays: z.array(z.number().int().min(1).max(7)).min(1).max(7),
  localTime,
  timeZoneIdentifier: ianaTimezone,
  timingNote: boundedText(120).optional(),
  startDate: dateOnly,
  endDate: dateOnly.optional(),
  pauseRanges: z.array(z.object({ startDate: dateOnly, endDate: dateOnly }).strict()).max(64),
  notificationPreference: z.enum(['product_and_timing', 'generic_private', 'disabled']),
  calendarOverlayEnabled: z.boolean(),
}).strict().superRefine((value, context) => {
  if (new Set(value.weekdays).size !== value.weekdays.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['weekdays'], message: 'schedule weekdays must be unique' });
  }
  if (value.endDate !== undefined && value.endDate < value.startDate) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['endDate'], message: 'schedule endDate must not precede startDate' });
  }
  if (value.endDate === undefined || value.endDate >= value.startDate) {
    const sortedPauses = [...value.pauseRanges].sort((left, right) => left.startDate.localeCompare(right.startDate));
    sortedPauses.forEach((pause, index) => {
      if (pause.endDate < pause.startDate) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['pauseRanges', index, 'endDate'], message: 'pause endDate must not precede startDate' });
      }
      if (pause.startDate < value.startDate) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['pauseRanges', index, 'startDate'], message: 'pause must be inside schedule start' });
      }
      if (value.endDate !== undefined && pause.endDate > value.endDate) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['pauseRanges', index, 'endDate'], message: 'pause must be inside schedule end' });
      }
      const previous = sortedPauses[index - 1];
      if (previous !== undefined && pause.startDate <= previous.endDate) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['pauseRanges', index, 'startDate'], message: 'pause ranges must not overlap' });
      }
    });
  }
});
export type SupplementSchedule = z.infer<typeof SupplementSchedule>;

const SupplementDose = z.object({
  amount: z.number().finite().positive().max(1_000_000).refine(value => Number.isInteger(value * 1_000), 'dose amount has at most three fractional decimals'),
  unit: boundedText(32),
}).strict();
export type SupplementDose = z.infer<typeof SupplementDose>;

export const SupplementSource = z.enum(['manual', 'package_label', 'imported']);
export type SupplementSource = z.infer<typeof SupplementSource>;

const SupplementProductLabelNote = z.object({
  text: boundedText(1_000),
  sourceDate: dateOnly,
}).strict();
export type SupplementProductLabelNote = z.infer<typeof SupplementProductLabelNote>;

export const SupplementPlan = z.object({
  id: SupplementID,
  name: boundedText(160),
  brand: boundedText(120),
  productIdentifier: boundedText(128).optional(),
  form: z.enum(['capsule', 'tablet', 'powder', 'liquid', 'softgel', 'other']),
  strength: boundedText(80),
  servingUnit: boundedText(32),
  userDose: SupplementDose.optional(),
  inventoryUnitsPerDose: z.number().finite().int().min(1).max(maxInventoryUnits),
  schedule: SupplementSchedule,
  source: SupplementSource,
  productLabelNote: SupplementProductLabelNote.optional(),
  notes: boundedText(1_000).optional(),
  stockUnits: inventoryUnits,
  reorderThreshold: inventoryUnits,
  expectedLeadTimeDays: z.number().int().nonnegative().max(365).optional(),
  expiryDate: timestamp.optional(),
  supplier: boundedText(160).optional(),
  reminderEnabled: z.boolean(),
  lockScreenRedacted: z.boolean(),
  revision,
  updatedAt: observedTimestamp,
}).strict().superRefine((value, context) => {
  if (value.schedule.notificationPreference === 'disabled' && value.reminderEnabled) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['reminderEnabled'], message: 'disabled notification preference cannot enable reminders' });
  }
});
export type SupplementPlan = z.infer<typeof SupplementPlan>;

export const SupplementOccurrenceState = z.enum(['planned', 'taken', 'snoozed', 'skipped', 'missed']);
export type SupplementOccurrenceState = z.infer<typeof SupplementOccurrenceState>;

export const SupplementOccurrence = z.object({
  id: SupplementID,
  planID: SupplementID,
  scheduledFor: timestamp,
  state: SupplementOccurrenceState,
  actedAt: observedTimestamp.optional(),
  snoozedUntil: timestamp.optional(),
  revision,
  updatedAt: observedTimestamp,
}).strict().superRefine((value, context) => {
  const hasActedAt = value.actedAt !== undefined;
  const hasSnoozedUntil = value.snoozedUntil !== undefined;

  if ((value.state === 'planned' || value.state === 'missed') && (hasActedAt || hasSnoozedUntil)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: `${value.state} occurrence cannot have action timestamps` });
  }
  if (value.state === 'snoozed') {
    if (!hasActedAt || !hasSnoozedUntil) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'snoozed occurrence requires actedAt and snoozedUntil' });
    } else if (Date.parse(value.snoozedUntil!) <= Date.parse(value.actedAt!)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['snoozedUntil'], message: 'snooze must end after the action' });
    }
  }
  if (value.state === 'taken' || value.state === 'skipped') {
    if (!hasActedAt || hasSnoozedUntil) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: `${value.state} occurrence requires only actedAt` });
    }
  }
});
export type SupplementOccurrence = z.infer<typeof SupplementOccurrence>;

const scalarValue = z.union([
  z.string().max(1_000),
  z.number().finite().min(-maxRevision).max(maxRevision),
  z.boolean(),
  z.null(),
]);

export const SupplementCorrection = z.object({
  id: SupplementID,
  entityKind: z.enum(['plan', 'schedule', 'occurrence', 'inventory']),
  entityID: SupplementID,
  field: boundedText(64),
  oldValue: scalarValue,
  newValue: scalarValue,
  actorID: SupplementID,
  correctedAt: observedTimestamp,
  reason: boundedText(500),
}).strict().superRefine((value, context) => {
  if (Object.is(value.oldValue, value.newValue)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['newValue'], message: 'correction oldValue and newValue must differ' });
  }
});
export type SupplementCorrection = z.infer<typeof SupplementCorrection>;

export const InventoryEventKind = z.enum(['taken_decrement', 'manual_adjustment', 'refill', 'correction']);
export type InventoryEventKind = z.infer<typeof InventoryEventKind>;

export const SupplementForecastAssumptions = z.object({
  dosesPerScheduledDay: z.number().finite().positive().max(100),
  scheduledDaysPerWeek: z.number().finite().int().min(1).max(7),
  inventoryUnitsPerDose: z.number().finite().int().min(1).max(maxInventoryUnits),
  asOf: observedTimestamp,
}).strict();
export type SupplementForecastAssumptions = z.infer<typeof SupplementForecastAssumptions>;

export const InventoryEvent = z.object({
  id: SupplementID,
  planID: SupplementID,
  kind: InventoryEventKind,
  delta: z.number().finite().int().min(-maxInventoryUnits).max(maxInventoryUnits).refine(value => value !== 0, 'inventory event delta must be nonzero'),
  stockAfter: inventoryUnits,
  occurredAt: observedTimestamp,
  occurrenceID: SupplementID.optional(),
  costCents: z.number().finite().int().nonnegative().max(maxRevision).optional(),
  batch: boundedText(128).optional(),
  expiry: timestamp.optional(),
  source: boundedText(128).optional(),
  forecastAssumptions: SupplementForecastAssumptions.optional(),
}).strict().superRefine((value, context) => {
  if (value.kind === 'taken_decrement') {
    if (value.occurrenceID === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['occurrenceID'], message: 'Taken decrement requires an occurrenceID' });
    }
    if (value.delta >= 0) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['delta'], message: 'Taken decrement must reduce inventory' });
    }
  } else {
    if (value.occurrenceID !== undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['occurrenceID'], message: 'only Taken decrement may reference an occurrence' });
    }
  }

  if (value.kind === 'refill' && value.delta <= 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['delta'], message: 'refill must increase inventory' });
  }
  if ((value.kind === 'manual_adjustment' || value.kind === 'correction') && value.delta === 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['delta'], message: 'inventory event delta must be nonzero' });
  }
  if (value.kind !== 'refill' && (value.costCents !== undefined || value.batch !== undefined || value.expiry !== undefined)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'cost, batch, and expiry are only valid for refills' });
  }
});
export type InventoryEvent = z.infer<typeof InventoryEvent>;

export const SupplementSnapshot = z.object({
  schemaVersion: z.literal(1),
  generatedAt: observedTimestamp,
  revision,
  plans: z.array(SupplementPlan).max(10_000),
  occurrences: z.array(SupplementOccurrence).max(100_000),
  corrections: z.array(SupplementCorrection).max(100_000),
  inventoryEvents: z.array(InventoryEvent).max(100_000),
}).strict().superRefine((value, context) => {
  const planIDs = new Set<string>();
  value.plans.forEach((plan, index) => {
    if (planIDs.has(plan.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['plans', index, 'id'], message: 'duplicate supplement plan id' });
    }
    planIDs.add(plan.id);
  });

  const occurrenceIDs = new Set<string>();
  value.occurrences.forEach((occurrence, index) => {
    if (occurrenceIDs.has(occurrence.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['occurrences', index, 'id'], message: 'duplicate supplement occurrence id' });
    }
    occurrenceIDs.add(occurrence.id);
    if (!planIDs.has(occurrence.planID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['occurrences', index, 'planID'], message: 'occurrence references an unknown plan' });
    }
  });

  const correctionIDs = new Set<string>();
  value.corrections.forEach((correction, index) => {
    if (correctionIDs.has(correction.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['corrections', index, 'id'], message: 'duplicate supplement correction id' });
    }
    correctionIDs.add(correction.id);
    const validEntity = correction.entityKind === 'plan' || correction.entityKind === 'schedule'
      ? planIDs.has(correction.entityID)
      : correction.entityKind === 'occurrence'
        ? occurrenceIDs.has(correction.entityID)
        : false;
    if (!validEntity && correction.entityKind !== 'inventory') {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['corrections', index, 'entityID'], message: 'correction references an unknown entity' });
    }
  });

  const inventoryEventIDs = new Set<string>();
  value.inventoryEvents.forEach((event, index) => {
    if (inventoryEventIDs.has(event.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['inventoryEvents', index, 'id'], message: 'duplicate inventory event id' });
    }
    inventoryEventIDs.add(event.id);
    const plan = value.plans.find(candidate => candidate.id === event.planID);
    if (plan === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['inventoryEvents', index, 'planID'], message: 'inventory event references an unknown plan' });
    }
    if (event.kind === 'taken_decrement' && event.occurrenceID !== undefined) {
      const occurrence = value.occurrences.find(candidate => candidate.id === event.occurrenceID);
      if (occurrence === undefined || occurrence.planID !== event.planID || occurrence.state !== 'taken') {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['inventoryEvents', index, 'occurrenceID'], message: 'Taken decrement occurrence link is invalid' });
      }
    }
  });

  value.corrections.forEach((correction, index) => {
    if (correction.entityKind === 'inventory' && !inventoryEventIDs.has(correction.entityID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['corrections', index, 'entityID'], message: 'correction references an unknown inventory event' });
    }
  });
});
export type SupplementSnapshot = z.infer<typeof SupplementSnapshot>;

export const SupplementAction = z.enum(['taken', 'snooze', 'skip']);
export type SupplementAction = z.infer<typeof SupplementAction>;

export const SupplementOccurrenceActionRequest = z.object({
  actionID: SupplementID,
  occurrenceID: SupplementID,
  planID: SupplementID,
  action: SupplementAction,
  occurredAt: observedTimestamp,
  snoozeUntil: timestamp.optional(),
  baseRevision: revision,
  sourceDeviceID: SupplementID,
}).strict().superRefine((value, context) => {
  if (value.action === 'snooze') {
    if (value.snoozeUntil === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['snoozeUntil'], message: 'snooze action requires snoozeUntil' });
    } else if (Date.parse(value.snoozeUntil) <= Date.parse(value.occurredAt)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['snoozeUntil'], message: 'snoozeUntil must be later than occurredAt' });
    }
  } else if (value.snoozeUntil !== undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['snoozeUntil'], message: 'only snooze actions may set snoozeUntil' });
  }
});
export type SupplementOccurrenceActionRequest = z.infer<typeof SupplementOccurrenceActionRequest>;

export const SupplementOccurrenceActionResponse = z.object({
  occurrence: SupplementOccurrence,
  inventoryDelta: z.number().int().max(0).min(-maxInventoryUnits),
  idempotent: z.boolean(),
  serverRevision: revision,
}).strict().superRefine((value, context) => {
  if (value.idempotent && value.inventoryDelta !== 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['inventoryDelta'], message: 'idempotent replay cannot change inventory' });
  }
  if ((!value.idempotent && value.occurrence.state !== 'taken') && value.inventoryDelta !== 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['inventoryDelta'], message: 'Snooze and Skip cannot change inventory' });
  }
});
export type SupplementOccurrenceActionResponse = z.infer<typeof SupplementOccurrenceActionResponse>;
