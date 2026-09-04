import { normalizeWindow, type UsageWindow } from '@iphone-life-os/contracts';

const WINDOW_KEYS = ['five_hour', 'seven_day'] as const;
const MAX_BODY_BYTES = 16_384;
export const claudeBodyLimit = MAX_BODY_BYTES;
export function constantTimeEqual(a: string, b: string): boolean {
  const aa = Buffer.from(a); const bb = Buffer.from(b); if (aa.length !== bb.length) return false;
  let diff = 0; for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i]; return diff === 0;
}
export function ingestClaudeStatusline(input: unknown, observedAt = new Date().toISOString()): UsageWindow[] {
  const root = input && typeof input === 'object' ? input as Record<string, unknown> : {};
  const limits = root.rate_limits && typeof root.rate_limits === 'object' ? root.rate_limits as Record<string, unknown> : root;
  return WINDOW_KEYS.map(key => normalizeWindow(limits[key], 'claude', key, 'claude.ai-statusline', observedAt));
}
export function validClaudeContentType(value: string | undefined): boolean { return value === 'application/json'; }
export { MAX_BODY_BYTES };
