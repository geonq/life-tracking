import { type Estimate, type UsageHistoryEntry } from '@iphone-life-os/contracts';

export function projectUsage(samples: UsageHistoryEntry[], now = new Date()): Estimate {
  const first = samples[0];
  const window = first?.window ?? (first?.durationMinutes === 10080 ? 'seven_day' : 'five_hour');
  const base = { provider: first?.provider ?? 'codex' as const, window, confidence: 'insufficient' as const, sampleSpanHours: 0, explanation: 'Insufficient samples from one provider, window, and reset cycle.', official: false as const };
  if (!first || samples.length < 2) return base;
  const same = samples.filter(s => s.provider === first.provider && s.window === first.window && s.durationMinutes === first.durationMinutes && s.resetAt === first.resetAt).sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt));
  if (same.length < 2) return base;
  const a = same[0]; const b = same[same.length - 1]; const span = (Date.parse(b.observedAt) - Date.parse(a.observedAt)) / 3600000;
  if (!(span > 0) || b.usedPercent < a.usedPercent) return { ...base, provider: first.provider, window, sampleSpanHours: Math.max(0, span), explanation: 'Counter decreased or reset rollover detected; projection unavailable.' };
  const velocity = (b.usedPercent - a.usedPercent) / span;
  const resetMs = b.resetAt ? Date.parse(b.resetAt) : NaN;
  const observedMs = Date.parse(b.observedAt);
  if (!Number.isFinite(resetMs) || !Number.isFinite(observedMs) || resetMs <= Math.max(observedMs, now.getTime())) {
    return { ...base, provider: first.provider, window, sampleSpanHours: span, explanation: 'No valid future reset boundary; projection unavailable.' };
  }
  const until = (resetMs - observedMs) / 3600000;
  const projected = Math.min(100, b.usedPercent + velocity * until);
  const exhaustion = velocity > 0 && projected >= 100 && Number.isFinite(resetMs) ? new Date(Date.parse(b.observedAt) + ((100 - b.usedPercent) / velocity) * 3600000).toISOString() : undefined;
  return { provider: first.provider, window, projectedPercentAtReset: projected, ...(exhaustion ? { estimatedExhaustionAt: exhaustion } : {}), velocityPercentPerHour: velocity, confidence: span >= 1 ? 'medium' : 'low', sampleSpanHours: span, explanation: 'Nonofficial estimate from increasing samples in the same reset cycle.', official: false };
}
