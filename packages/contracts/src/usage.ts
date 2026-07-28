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
export const UsageProvenance = z.object({
  source: z.string().min(1), observedAt: iso,
  freshness: z.enum(['fresh', 'stale', 'unknown']), official: z.boolean(),
  quality: z.enum(['observed', 'estimated', 'unavailable']), connectorState: ConnectorState,
});
export type UsageProvenance = z.infer<typeof UsageProvenance>;
export const UsageWindow = z.object({
  provider: Provider, window: UsageWindowKind, durationMinutes: z.number().int().positive(),
  usedPercent: z.number().finite().min(0).max(100).optional(), resetAt: iso.optional(),
  availability: z.enum(['observed', 'unavailable']), provenance: UsageProvenance,
});
export type UsageWindow = z.infer<typeof UsageWindow>;
export const UsageHistoryEntry = z.object({
  provider: Provider, window: UsageWindowKind, durationMinutes: z.number().int().positive(),
  usedPercent: z.number().finite().min(0).max(100), resetAt: iso.optional(), observedAt: iso,
});
export type UsageHistoryEntry = z.infer<typeof UsageHistoryEntry>;
export const Estimate = z.object({
  provider: Provider, window: UsageWindowKind, projectedPercentAtReset: z.number().finite().min(0).max(100).optional(),
  estimatedExhaustionAt: iso.optional(), velocityPercentPerHour: z.number().finite().nonnegative().optional(),
  confidence: z.enum(['low', 'medium', 'high', 'insufficient']), sampleSpanHours: z.number().finite().nonnegative(),
  explanation: z.string(), official: z.literal(false),
});
export type Estimate = z.infer<typeof Estimate>;
export const UnifiedUsage = z.object({ generatedAt: iso, windows: z.array(UsageWindow), estimates: z.array(Estimate), connectors: z.record(ConnectorState) });
export type UnifiedUsage = z.infer<typeof UnifiedUsage>;

export function normalizeWindow(input: unknown, provider: Provider, window: UsageWindowKind, source: string, observedAt = new Date().toISOString()): UsageWindow {
  const root = input && typeof input === 'object' ? input as Record<string, unknown> : {};
  const used = [root.usedPercent, root.used_percentage, root.usedPercentage].find(v => typeof v === 'number') as number | undefined;
  const rawReset = root.resetsAt ?? root.resets_at ?? root.resetAt ?? root.reset_at;
  const resetAt = typeof rawReset === 'number' ? new Date(rawReset * 1000).toISOString() : typeof rawReset === 'string' && Number.isFinite(Date.parse(rawReset)) ? new Date(rawReset).toISOString() : undefined;
  const valid = used !== undefined && Number.isFinite(used) && used >= 0 && used <= 100;
  const durationMinutes = window === 'five_hour' ? 300 : 10080;
  const connectorState: ConnectorState = valid ? (used >= 100 ? 'rate_limited' : 'healthy') : 'unavailable';
  return {
    provider, window, durationMinutes, ...(valid ? { usedPercent: used } : {}), ...(resetAt ? { resetAt } : {}),
    availability: valid ? 'observed' : 'unavailable',
    provenance: { source, observedAt, freshness: 'fresh', official: valid, quality: valid ? 'observed' : 'unavailable', connectorState },
  };
}
