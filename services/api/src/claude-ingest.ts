import { createHash, timingSafeEqual } from 'node:crypto';
import { normalizeWindow, type UsageWindow } from '@iphone-life-os/contracts';

const WINDOW_KEYS = ['five_hour', 'seven_day'] as const;
const MAX_BODY_BYTES = 16_384;
export const claudeBodyLimit = MAX_BODY_BYTES;

const digest = (value: string): Buffer => createHash('sha256').update(value, 'utf8').digest();

export function constantTimeEqual(a: string, b: string): boolean {
  // Hash both inputs first so timingSafeEqual always receives fixed-size
  // digests. Secret length validation remains the caller's responsibility.
  return timingSafeEqual(digest(a), digest(b));
}
export function ingestClaudeStatusline(input: unknown, observedAt = new Date().toISOString()): UsageWindow[] {
  const root = input && typeof input === 'object' ? input as Record<string, unknown> : {};
  const limits = root.rate_limits && typeof root.rate_limits === 'object' ? root.rate_limits as Record<string, unknown> : root;
  return WINDOW_KEYS.map(key => normalizeWindow(limits[key], 'claude', key, 'claude.ai-statusline', observedAt));
}
export function validClaudeContentType(value: string | undefined): boolean { return value === 'application/json'; }
export { MAX_BODY_BYTES };
