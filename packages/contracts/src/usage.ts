import { z } from 'zod';

export const Provider = z.enum(['codex', 'claude']);
export type Provider = z.infer<typeof Provider>;
export const UsageWindowKind = z.enum(['five_hour', 'seven_day']);
export type UsageWindowKind = z.infer<typeof UsageWindowKind>;
export const ConnectorState = z.enum([
  'healthy', 'refresh_due', 'reauth_required', 'revoked', 'rate_limited', 'unavailable',
]);
export type ConnectorState = z.infer<typeof ConnectorState>;

const iso = z.string().datetime({ offset: true });
const maximumClockSkewMs = 5_000;
const observedTimestamp = iso.refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'future observation timestamp',
);
export const UsageProvenance = z.object({
  source: z.string().min(1), observedAt: observedTimestamp,
  freshness: z.enum(['fresh', 'stale', 'unknown']), official: z.boolean(),
  quality: z.enum(['observed', 'estimated', 'unavailable']), connectorState: ConnectorState,
}).strict();
export type UsageProvenance = z.infer<typeof UsageProvenance>;
export const UsageWindow = z.object({
  provider: Provider, window: UsageWindowKind, durationMinutes: z.number().int().positive(),
  usedPercent: z.number().finite().min(0).max(100).optional(), resetAt: iso.optional(),
  availability: z.enum(['observed', 'unavailable']), provenance: UsageProvenance,
}).strict().superRefine((value, context) => {
  const expectedMinutes = value.window === 'five_hour' ? 300 : 10_080;
  if (value.durationMinutes !== expectedMinutes) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'usage duration does not match window' });
  }
  if (value.availability === 'unavailable') {
    if (value.usedPercent !== undefined || value.resetAt !== undefined || value.provenance.official ||
        value.provenance.quality !== 'unavailable' ||
        value.provenance.connectorState === 'healthy' || value.provenance.connectorState === 'refresh_due') {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'unavailable usage window is contradictory' });
    }
  } else if (value.usedPercent === undefined || !value.provenance.official || value.provenance.quality !== 'observed') {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'observed usage window is incomplete' });
  } else {
    const expectedFreshness = freshnessFromObservedAt(value.provenance.observedAt);
    const expectedConnector = expectedFreshness === 'stale' ? 'refresh_due'
      : value.usedPercent >= 100 ? 'rate_limited' : 'healthy';
    if (expectedFreshness === 'unknown' || value.provenance.freshness !== expectedFreshness ||
        value.provenance.connectorState !== expectedConnector) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'observed usage provenance is contradictory' });
    }
  }
});
export type UsageWindow = z.infer<typeof UsageWindow>;
export const UsageHistoryEntry = z.object({
  provider: Provider, window: UsageWindowKind, durationMinutes: z.number().int().positive(),
  usedPercent: z.number().finite().min(0).max(100), resetAt: iso.optional(), observedAt: observedTimestamp,
}).strict().superRefine((value, context) => {
  const expectedMinutes = value.window === 'five_hour' ? 300 : 10_080;
  if (value.durationMinutes !== expectedMinutes) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'history duration does not match window' });
  }
});
export type UsageHistoryEntry = z.infer<typeof UsageHistoryEntry>;
export const Estimate = z.object({
  provider: Provider, window: UsageWindowKind, projectedPercentAtReset: z.number().finite().min(0).max(100).optional(),
  estimatedExhaustionAt: iso.optional(), velocityPercentPerHour: z.number().finite().nonnegative().optional(),
  confidence: z.enum(['low', 'medium', 'high', 'insufficient']), sampleSpanHours: z.number().finite().nonnegative(),
  explanation: z.string(), official: z.literal(false),
}).strict();
export type Estimate = z.infer<typeof Estimate>;
const UsageConnectors = z.object({ codex: ConnectorState, claude: ConnectorState }).strict();
export const UnifiedUsage = z.object({
  generatedAt: observedTimestamp, windows: z.array(UsageWindow), estimates: z.array(Estimate), connectors: UsageConnectors,
}).strict().superRefine((value, context) => {
  const windows = new Set<string>();
  for (const window of value.windows) {
    const key = `${window.provider}:${window.window}`;
    if (windows.has(key)) context.addIssue({ code: z.ZodIssueCode.custom, message: `duplicate usage window ${key}` });
    windows.add(key);
  }
  const estimates = new Set<string>();
  for (const estimate of value.estimates) {
    const key = `${estimate.provider}:${estimate.window}`;
    if (estimates.has(key)) context.addIssue({ code: z.ZodIssueCode.custom, message: `duplicate usage estimate ${key}` });
    estimates.add(key);
  }
});
export type UnifiedUsage = z.infer<typeof UnifiedUsage>;

export function normalizeWindow(input: unknown, provider: Provider, window: UsageWindowKind, source: string, observedAt = new Date().toISOString()): UsageWindow {
  const root = input && typeof input === 'object' ? input as Record<string, unknown> : {};
  const used = [root.usedPercent, root.used_percentage, root.usedPercentage].find(v => typeof v === 'number') as number | undefined;
  const rawReset = root.resetsAt ?? root.resets_at ?? root.resetAt ?? root.reset_at;
  const resetAt = typeof rawReset === 'number' && Number.isFinite(rawReset) && Number.isFinite(new Date(rawReset * 1000).getTime())
    ? new Date(rawReset * 1000).toISOString()
    : typeof rawReset === 'string' && Number.isFinite(Date.parse(rawReset))
      ? new Date(rawReset).toISOString()
      : undefined;
  const freshness = freshnessFromObservedAt(observedAt);
  const valid = used !== undefined && Number.isFinite(used) && used >= 0 && used <= 100 && freshness !== 'unknown';
  const durationMinutes = window === 'five_hour' ? 300 : 10080;
  const connectorState: ConnectorState = !valid ? 'unavailable'
    : freshness === 'fresh' ? (used >= 100 ? 'rate_limited' : 'healthy')
      : freshness === 'stale' ? 'refresh_due' : 'unavailable';
  return {
    provider, window, durationMinutes, ...(valid ? { usedPercent: used } : {}), ...(valid && resetAt ? { resetAt } : {}),
    availability: valid ? 'observed' : 'unavailable',
    provenance: { source, observedAt, freshness: valid ? freshness : 'unknown', official: valid,
      quality: valid ? 'observed' : 'unavailable', connectorState },
  };
}

export function freshnessFromObservedAt(observedAt: string, now = Date.now()): 'fresh' | 'stale' | 'unknown' {
  const observed = Date.parse(observedAt);
  const age = now - observed;
  if (!Number.isFinite(observed) || age < -maximumClockSkewMs) return 'unknown';
  return age <= 15 * 60_000 ? 'fresh' : 'stale';
}
