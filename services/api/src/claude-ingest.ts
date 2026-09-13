import { createHash, timingSafeEqual } from 'node:crypto';
import { normalizeWindow, type UsageWindow } from '@iphone-life-os/contracts';
import {
  INGEST_SECRET_MAX_LENGTH,
  INGEST_SECRET_MIN_LENGTH,
  validateIngestSecret,
} from './ingest-secret.js';

const WINDOW_KEYS = ['five_hour', 'seven_day'] as const;
const MAX_BODY_BYTES = 16_384;
export const claudeBodyLimit = MAX_BODY_BYTES;

export const CLAUDE_SECRET_MIN_LENGTH = INGEST_SECRET_MIN_LENGTH;
export const CLAUDE_SECRET_MAX_LENGTH = INGEST_SECRET_MAX_LENGTH;

const digest = (value: string): Buffer => createHash('sha256').update(value, 'utf8').digest();

export function constantTimeEqual(a: string, b: string): boolean {
  // Hash both inputs first so timingSafeEqual always receives fixed-size
  // digests. Validate only after the fixed-size comparison so a short or
  // malformed candidate cannot turn credential comparison into a length oracle.
  const equal = timingSafeEqual(digest(a), digest(b));
  return validateIngestSecret(a) !== undefined && validateIngestSecret(b) !== undefined && equal;
}

/** The startup and request paths accept only the same bounded file-secret form. */
export function isValidClaudeSecret(value: unknown): value is string {
  return typeof value === 'string' && validateIngestSecret(value) !== undefined;
}
export function ingestClaudeStatusline(input: unknown, observedAt = new Date().toISOString()): UsageWindow[] {
  const root = input && typeof input === 'object' ? input as Record<string, unknown> : {};
  const limits = root.rate_limits && typeof root.rate_limits === 'object' ? root.rate_limits as Record<string, unknown> : root;
  return WINDOW_KEYS.map(key => normalizeWindow(limits[key], 'claude', key, 'claude.ai-statusline', observedAt));
}
export function validClaudeContentType(value: string | undefined): boolean { return value === 'application/json'; }
export { MAX_BODY_BYTES };
