import { z } from 'zod';

/**
 * Shared synchronization metadata.  Domain payloads remain domain-owned, but
 * every mutable boundary uses the same small, versioned vocabulary for
 * authority, revisions, replay protection, and deletion propagation.
 *
 * These contracts intentionally do not manufacture a value for a provider
 * that is unavailable.  `state` is metadata about the durable record, not a
 * substitute for the domain's observed/unavailable payload branch.
 */
export const SYNC_SCHEMA_VERSION = 1;
export const SyncSchemaVersion = z.literal(SYNC_SCHEMA_VERSION);

export const SyncDomain = z.enum([
  'calendar', 'nutrition', 'supplements', 'usage', 'finance', 'clipper', 'fitness',
]);
export type SyncDomain = z.infer<typeof SyncDomain>;

export const SyncAuthority = z.enum(['api', 'gateway', 'device', 'provider', 'system']);
export type SyncAuthority = z.infer<typeof SyncAuthority>;

/** Response returned by the retired Node Calendar route. */
export const CalendarAuthorityUnavailable = z.object({
  error: z.literal('calendar_authority_gateway_only'),
  authority: z.literal('gateway'),
}).strict();
export type CalendarAuthorityUnavailable = z.infer<typeof CalendarAuthorityUnavailable>;

export const SyncOperation = z.enum(['upsert', 'delete']);
export type SyncOperation = z.infer<typeof SyncOperation>;

export const SyncRecordState = z.enum(['observed', 'partial', 'stale', 'unavailable', 'deleted']);
export type SyncRecordState = z.infer<typeof SyncRecordState>;

const maximumClockSkewMs = 5_000;
const maximumRevision = Number.MAX_SAFE_INTEGER;
const maximumJournalRecords = 10_000;

/** Opaque IDs are safe to persist and echo, but cannot contain a path. */
export const SyncEntityID = z.string().min(1).max(128).regex(
  /^[A-Za-z0-9](?:[A-Za-z0-9._:-]{0,127})$/,
  'unsafe sync entity identifier',
);
export type SyncEntityID = z.infer<typeof SyncEntityID>;

/** Visible ASCII keeps header and journal delimiters unambiguous. */
export const SyncIdempotencyKey = z.string().regex(
  /^[\x21-\x7e]{1,128}$/,
  'invalid sync idempotency key',
);
export type SyncIdempotencyKey = z.infer<typeof SyncIdempotencyKey>;

export const SyncRevision = z.number().finite().int().nonnegative().max(maximumRevision);
export type SyncRevision = z.infer<typeof SyncRevision>;

export const SyncPositiveRevision = SyncRevision.refine(value => value > 0, 'revision must be positive');

export const SyncFingerprint = z.string().regex(/^[0-9a-f]{64}$/, 'invalid SHA-256 fingerprint');

export const SyncTimestamp = z.string().datetime({ offset: true }).refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'sync timestamp is too far in the future',
);

export const SyncSource = z.string().trim().min(1).max(128);

export const SyncIdempotencyRecord = z.object({
  key: SyncIdempotencyKey,
  fingerprint: SyncFingerprint,
  revision: SyncRevision,
}).strict();
export type SyncIdempotencyRecord = z.infer<typeof SyncIdempotencyRecord>;

/**
 * A tombstone is retained after deletion so an offline writer cannot
 * resurrect an older record.  Tombstones are metadata only; the domain
 * payload remains responsible for its own deletion representation.
 */
export const SyncTombstone = z.object({
  schemaVersion: SyncSchemaVersion,
  domain: SyncDomain,
  entityID: SyncEntityID,
  revision: SyncPositiveRevision,
  idempotencyKey: SyncIdempotencyKey,
  authority: SyncAuthority,
  deletedAt: SyncTimestamp,
}).strict();
export type SyncTombstone = z.infer<typeof SyncTombstone>;

/** Durable sidecar shape used by the API and gateway authorities. */
export const SyncDomainMetadata = z.object({
  schemaVersion: SyncSchemaVersion,
  domain: SyncDomain,
  authority: SyncAuthority,
  revision: SyncRevision,
  bodyDigest: SyncFingerprint,
  idempotency: z.array(SyncIdempotencyRecord).max(maximumJournalRecords),
  tombstones: z.array(SyncTombstone).max(maximumJournalRecords),
}).strict().superRefine((value, context) => {
  const keys = new Set<string>();
  value.idempotency.forEach((record, index) => {
    if (keys.has(record.key)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['idempotency', index, 'key'], message: 'duplicate idempotency key' });
    }
    keys.add(record.key);
    if (record.revision > value.revision) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['idempotency', index, 'revision'], message: 'journal revision exceeds authority revision' });
    }
  });

  const tombstoneKeys = new Set<string>();
  value.tombstones.forEach((tombstone, index) => {
    const identity = `${tombstone.domain}:${tombstone.entityID}`;
    if (tombstone.domain !== value.domain) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'domain'], message: 'tombstone domain does not match metadata domain' });
    }
    if (tombstone.authority !== value.authority) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'authority'], message: 'tombstone authority does not match metadata authority' });
    }
    if (keys.has(tombstone.idempotencyKey)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'idempotencyKey'], message: 'tombstone reuses an idempotency key' });
    }
    keys.add(tombstone.idempotencyKey);
    if (tombstoneKeys.has(identity)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'entityID'], message: 'duplicate active tombstone identity' });
    }
    tombstoneKeys.add(identity);
    if (tombstone.revision > value.revision) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'revision'], message: 'tombstone revision exceeds authority revision' });
    }
  });
});
export type SyncDomainMetadata = z.infer<typeof SyncDomainMetadata>;

export const SyncWriteReceipt = z.object({
  schemaVersion: SyncSchemaVersion,
  domain: SyncDomain,
  entityID: SyncEntityID,
  revision: SyncPositiveRevision,
  operation: SyncOperation,
  idempotencyKey: SyncIdempotencyKey,
  authority: SyncAuthority,
  committedAt: SyncTimestamp,
}).strict();
export type SyncWriteReceipt = z.infer<typeof SyncWriteReceipt>;

export const SyncStateMetadata = z.object({
  schemaVersion: SyncSchemaVersion,
  domain: SyncDomain,
  authority: SyncAuthority,
  revision: SyncRevision,
  state: SyncRecordState,
  source: SyncSource,
  updatedAt: SyncTimestamp,
  tombstone: SyncTombstone.optional(),
}).strict().superRefine((value, context) => {
  if (value.state === 'deleted' && value.tombstone === undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstone'], message: 'deleted state requires a tombstone' });
  }
  if (value.state !== 'deleted' && value.tombstone !== undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstone'], message: 'only deleted state may carry a tombstone' });
  }
  if (value.tombstone !== undefined && (value.tombstone.domain !== value.domain || value.tombstone.authority !== value.authority)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstone'], message: 'tombstone authority/domain does not match state metadata' });
  }
  if (value.tombstone !== undefined && value.tombstone.revision > value.revision) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstone', 'revision'], message: 'tombstone revision exceeds state revision' });
  }
  if (value.state === 'deleted' && value.tombstone !== undefined && value.tombstone.revision !== value.revision) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstone', 'revision'], message: 'deleted state revision must equal tombstone revision' });
  }
});
export type SyncStateMetadata = z.infer<typeof SyncStateMetadata>;

/** Versioned conditional transport facts shared by ETag/If-Match clients. */
export const SyncTransportHeaders = z.object({
  schemaVersion: SyncSchemaVersion,
  domain: SyncDomain,
  revision: SyncRevision,
  // A quote is not valid inside the opaque tag value. Keeping it excluded
  // prevents a nested quote from crossing the contract boundary.
  etag: z.string().regex(/^"[\x21\x23-\x7e]+"$/, 'invalid strong ETag'),
  idempotencyKey: SyncIdempotencyKey,
  ifMatch: z.string().regex(/^"[\x21\x23-\x7e]+"$/, 'invalid If-Match ETag').optional(),
}).strict();
export type SyncTransportHeaders = z.infer<typeof SyncTransportHeaders>;
