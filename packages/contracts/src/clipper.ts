import { z } from 'zod';
import { freshnessFromObservedAt } from './usage.js';

/**
 * Provider-neutral Clipper analytics.  This contract intentionally models the
 * shape LifeOS can consume without naming a platform or scraping strategy.
 * A connector must supply the same audited shape before any observed values
 * are accepted by the gateway.
 */
const observedISO = z.string().datetime({ offset: true });
const observedTimestamp = observedISO.refine(
  value => Date.parse(value) <= Date.now() + 5_000,
  'future clipper observation timestamp',
);
const maximumCents = Number.MAX_SAFE_INTEGER;
const ClipperConnectorState = z.enum([
  'healthy', 'refresh_due', 'reauth_required', 'revoked', 'rate_limited', 'unavailable',
]);
const Provenance = z.object({
  source: z.string().trim().min(1),
  observedAt: observedTimestamp,
  freshness: z.enum(['fresh', 'stale', 'unknown']),
  quality: z.enum(['observed', 'estimated', 'partial', 'unavailable']),
  connectorState: ClipperConnectorState,
});

const observedProvenance = Provenance.extend({
  quality: z.literal('observed'),
  freshness: z.enum(['fresh', 'stale']),
  connectorState: z.enum(['healthy', 'refresh_due']),
}).strict().superRefine((value, context) => {
  validateObservedProvenance(value, context);
});

function validateObservedProvenance(
  value: { observedAt: string; freshness: 'fresh' | 'stale'; connectorState: 'healthy' | 'refresh_due' },
  context: z.RefinementCtx,
) {
  const freshness = freshnessFromObservedAt(value.observedAt);
  const connector = freshness === 'fresh' ? 'healthy' : freshness === 'stale' ? 'refresh_due' : undefined;
  if (!connector || value.freshness !== freshness || value.connectorState !== connector) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'observed Clipper provenance is contradictory' });
  }
}

const unavailableProvenance = Provenance.extend({
  quality: z.literal('unavailable'),
  freshness: z.literal('unknown'),
}).strict().superRefine((value, context) => {
  if (value.connectorState === 'healthy' || value.connectorState === 'refresh_due') {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'unavailable Clipper data cannot have a healthy connector' });
  }
});

export const ClipperMetricAvailability = z.enum(['observed', 'unavailable']);
export type ClipperMetricAvailability = z.infer<typeof ClipperMetricAvailability>;

const observedCount = z.object({
  availability: z.literal('observed'),
  value: z.number().int().nonnegative().max(maximumCents),
  provenance: observedProvenance,
}).strict();
const unavailableCount = z.object({
  availability: z.literal('unavailable'),
  provenance: unavailableProvenance,
}).strict();
export const ClipperCountMetric = z.discriminatedUnion('availability', [observedCount, unavailableCount]);
export type ClipperCountMetric = z.infer<typeof ClipperCountMetric>;

const observedRevenue = z.object({
  availability: z.literal('observed'),
  amountCents: z.number().int().nonnegative().max(maximumCents),
  currency: z.literal('EUR'),
  provenance: observedProvenance,
}).strict();
const unavailableRevenue = z.object({
  availability: z.literal('unavailable'),
  currency: z.literal('EUR'),
  provenance: unavailableProvenance,
}).strict();
export const ClipperRevenueMetric = z.discriminatedUnion('availability', [observedRevenue, unavailableRevenue]);
export type ClipperRevenueMetric = z.infer<typeof ClipperRevenueMetric>;

export const ClipperMetricSet = z.object({
  views: ClipperCountMetric,
  subscribers: ClipperCountMetric,
  revenue: ClipperRevenueMetric,
}).strict();
export type ClipperMetricSet = z.infer<typeof ClipperMetricSet>;

export const ClipperTrendPoint = z.object({
  at: observedTimestamp,
  metrics: ClipperMetricSet,
}).strict();
export type ClipperTrendPoint = z.infer<typeof ClipperTrendPoint>;

export const ClipperBreakdown = z.object({
  id: z.string().trim().min(1),
  label: z.string().trim().min(1),
  periodStart: observedISO,
  periodEnd: observedISO,
  metrics: ClipperMetricSet,
}).strict().superRefine((value, context) => {
  if (Date.parse(value.periodEnd) <= Date.parse(value.periodStart)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['periodEnd'], message: 'Clipper breakdown period must be positive' });
  }
});
export type ClipperBreakdown = z.infer<typeof ClipperBreakdown>;

export const ClipperBot = z.object({
  id: z.string().trim().min(1),
  name: z.string().trim().min(1),
  metrics: ClipperMetricSet,
  breakdowns: z.array(ClipperBreakdown),
}).strict().superRefine((value, context) => {
  const ids = new Set<string>();
  value.breakdowns.forEach((breakdown, index) => {
    if (ids.has(breakdown.id)) context.addIssue({ code: z.ZodIssueCode.custom, path: ['breakdowns', index, 'id'], message: 'duplicate Clipper breakdown id' });
    ids.add(breakdown.id);
  });
});
export type ClipperBot = z.infer<typeof ClipperBot>;

export const ClipperAccount = z.object({
  id: z.string().trim().min(1),
  name: z.string().trim().min(1),
  metrics: ClipperMetricSet,
  bots: z.array(ClipperBot),
  breakdowns: z.array(ClipperBreakdown),
}).strict().superRefine((value, context) => {
  const botIDs = new Set<string>();
  value.bots.forEach((bot, index) => {
    if (botIDs.has(bot.id)) context.addIssue({ code: z.ZodIssueCode.custom, path: ['bots', index, 'id'], message: 'duplicate Clipper bot id within account' });
    botIDs.add(bot.id);
  });
  const breakdownIDs = new Set<string>();
  value.breakdowns.forEach((breakdown, index) => {
    if (breakdownIDs.has(breakdown.id)) context.addIssue({ code: z.ZodIssueCode.custom, path: ['breakdowns', index, 'id'], message: 'duplicate Clipper breakdown id' });
    breakdownIDs.add(breakdown.id);
  });
});
export type ClipperAccount = z.infer<typeof ClipperAccount>;

const hasObservedMetric = (metrics: ClipperMetricSet): boolean =>
  metrics.views.availability === 'observed'
  || metrics.subscribers.availability === 'observed'
  || metrics.revenue.availability === 'observed';

const hasObservedDetail = (account: ClipperAccount): boolean =>
  hasObservedMetric(account.metrics)
  || account.bots.some(bot => hasObservedMetric(bot.metrics)
    || bot.breakdowns.some(breakdown => hasObservedMetric(breakdown.metrics)))
  || account.breakdowns.some(breakdown => hasObservedMetric(breakdown.metrics));

const observedSnapshot = z.object({
  schemaVersion: z.literal(1),
  availability: z.literal('observed'),
  generatedAt: observedTimestamp,
  currency: z.literal('EUR'),
  metrics: ClipperMetricSet,
  accounts: z.array(ClipperAccount),
  trends: z.array(ClipperTrendPoint),
  breakdowns: z.array(ClipperBreakdown),
  provenance: Provenance.extend({
    quality: z.enum(['observed', 'partial']),
    freshness: z.enum(['fresh', 'stale']),
    connectorState: z.enum(['healthy', 'refresh_due']),
  }).strict().superRefine((value, context) => {
    validateObservedProvenance(value, context);
  }),
}).strict().superRefine((value, context) => {
  const accountIDs = new Set<string>();
  value.accounts.forEach((account, index) => {
    if (accountIDs.has(account.id)) context.addIssue({ code: z.ZodIssueCode.custom, path: ['accounts', index, 'id'], message: 'duplicate Clipper account id' });
    accountIDs.add(account.id);
  });
  const breakdownIDs = new Set<string>();
  value.breakdowns.forEach((breakdown, index) => {
    if (breakdownIDs.has(breakdown.id)) context.addIssue({ code: z.ZodIssueCode.custom, path: ['breakdowns', index, 'id'], message: 'duplicate Clipper breakdown id' });
    breakdownIDs.add(breakdown.id);
  });
  const metricObservationTimestamps = (metrics: ClipperMetricSet): string[] => [
    metrics.views.provenance.observedAt,
    metrics.subscribers.provenance.observedAt,
    metrics.revenue.provenance.observedAt,
  ];
  const latest = [
    value.provenance.observedAt,
    ...metricObservationTimestamps(value.metrics),
    ...value.accounts.flatMap(account => [
      ...metricObservationTimestamps(account.metrics),
      ...account.bots.flatMap(bot => [
        ...metricObservationTimestamps(bot.metrics),
        ...bot.breakdowns.flatMap(breakdown => metricObservationTimestamps(breakdown.metrics)),
      ]),
      ...account.breakdowns.flatMap(breakdown => metricObservationTimestamps(breakdown.metrics)),
    ]),
    ...value.trends.flatMap(trend => [trend.at, ...metricObservationTimestamps(trend.metrics)]),
    ...value.breakdowns.flatMap(breakdown => metricObservationTimestamps(breakdown.metrics)),
  ].map(Date.parse).filter(Number.isFinite);
  if (!hasObservedMetric(value.metrics) && !value.accounts.some(hasObservedDetail)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['provenance', 'quality'], message: 'observed Clipper snapshot has no observed metric' });
  }
  if (latest.some(timestamp => timestamp > Date.parse(value.generatedAt) + 5_000)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['generatedAt'], message: 'Clipper snapshot generation must cover metric observations' });
  }
});

const unavailableSnapshot = z.object({
  schemaVersion: z.literal(1),
  availability: z.literal('unavailable'),
  generatedAt: observedTimestamp,
  currency: z.literal('EUR'),
  provenance: unavailableProvenance,
}).strict();

// The observed branch carries cross-field refinements (a ZodEffects), so use
// a regular union here; discriminatedUnion only accepts plain object branches.
export const ClipperSnapshot = z.union([observedSnapshot, unavailableSnapshot]);
export type ClipperSnapshot = z.infer<typeof ClipperSnapshot>;

export function parseClipperSnapshot(input: unknown): ClipperSnapshot {
  return ClipperSnapshot.parse(input);
}

export function unavailableClipperSnapshot(generatedAt = new Date().toISOString()): ClipperSnapshot {
  return ClipperSnapshot.parse({
    schemaVersion: 1,
    availability: 'unavailable',
    generatedAt,
    currency: 'EUR',
    provenance: {
      source: 'no-authorized-clipper-source',
      observedAt: generatedAt,
      freshness: 'unknown',
      quality: 'unavailable',
      connectorState: 'unavailable',
    },
  });
}
