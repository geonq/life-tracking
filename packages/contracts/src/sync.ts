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

// ---------------------------------------------------------------------------
// Manual imported-finance ledger synchronization
// ---------------------------------------------------------------------------

/**
 * The manual-import ledger is intentionally a separate wire contract from
 * FinanceSummary. Enable Banking owns the live connector summary; this
 * contract carries only user-confirmed CSV observations between devices and
 * the Windows gateway authority.
 */
export const FINANCE_IMPORTED_SYNC_SCHEMA_VERSION = 2;
export const FinanceImportedSyncSchemaVersion = z.literal(FINANCE_IMPORTED_SYNC_SCHEMA_VERSION);
export const FinanceImportedSyncDomain = z.literal('finance');
export const FinanceImportedSyncLedger = z.literal('manual_import');
export const FinanceImportedSource = z.enum(['tradeRepublicCSV', 'genericCSV']);
export type FinanceImportedSource = z.infer<typeof FinanceImportedSource>;
export const FinanceImportedKind = z.enum(['cash', 'investmentOrder']);
export type FinanceImportedKind = z.infer<typeof FinanceImportedKind>;
export const FinanceImportedCategory = z.enum([
  'groceries', 'dining', 'transport', 'shopping', 'bills', 'subscriptions',
  'health', 'travel', 'transfers', 'fees', 'taxes', 'investments', 'income',
  'cash', 'uncategorized',
]);
export type FinanceImportedCategory = z.infer<typeof FinanceImportedCategory>;

export const FINANCE_IMPORTED_MAX_RECORDS = 10_000;
export const FINANCE_IMPORTED_MAX_TOMBSTONES = 10_000;
export const FINANCE_IMPORTED_MAX_OPERATIONS = 512;
export const FINANCE_IMPORTED_MAX_BODY_BYTES = 512 * 1024;
export const FINANCE_IMPORTED_MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
export const FINANCE_IMPORTED_MAX_REQUEST_BYTES = 512 * 1024;

const financeImportedTimestamp = z.string().datetime({ offset: true }).refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'finance import timestamp is too far in the future',
);
const financeImportedWhitespace = new Set([
  0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x0020, 0x0085, 0x00a0, 0x1680,
  ...Array.from({ length: 11 }, (_, index) => 0x2000 + index),
  0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff,
]);
const hasNoFinanceImportedEdgeWhitespace = (value: string) => {
  const codePoints = Array.from(value, character => character.codePointAt(0) ?? 0);
  return codePoints.length > 0
    && !financeImportedWhitespace.has(codePoints[0])
    && !financeImportedWhitespace.has(codePoints[codePoints.length - 1]);
};
const financeImportedText = (maximum: number) => z.string()
  .min(1)
  .refine(hasNoFinanceImportedEdgeWhitespace, 'finance import text must not have surrounding whitespace')
  .refine(value => new TextEncoder().encode(value).byteLength <= maximum, `finance import text exceeds ${maximum} UTF-8 bytes`);
const financeImportedNullableText = (maximum: number) => financeImportedText(maximum).nullable();
const financeImportedCents = z.number().finite().int().min(-Number.MAX_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER);
const financeImportedRevision = z.number().finite().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const financeImportedPositiveRevision = financeImportedRevision.refine(value => value > 0, 'revision must be positive');

export const FinanceImportedInvestment = z.object({
  symbol: financeImportedNullableText(64),
  assetClass: financeImportedNullableText(64),
  quantity: financeImportedNullableText(128),
  unitPriceCents: financeImportedCents.nullable(),
  tradeType: financeImportedNullableText(64),
  currency: z.literal('EUR'),
}).strict();
export type FinanceImportedInvestment = z.infer<typeof FinanceImportedInvestment>;

/** One complete source observation. Optional Swift values are encoded as JSON nulls. */
export const FinanceImportedRecord = z.object({
  recordID: z.string().uuid().transform(value => value.toLowerCase()),
  /** Authority revision of the source observation. Zero is used only in a new local write. */
  sourceRevision: financeImportedRevision,
  bookedAt: financeImportedTimestamp,
  amountCents: financeImportedCents,
  description: financeImportedText(512),
  categoryOverride: FinanceImportedCategory.nullable(),
  sourceCategory: financeImportedNullableText(128),
  providerCode: financeImportedNullableText(64),
  source: FinanceImportedSource,
  importedAt: financeImportedTimestamp,
  kind: FinanceImportedKind,
  investment: FinanceImportedInvestment.nullable(),
}).strict().superRefine((value, context) => {
  if (value.kind === 'cash' && value.investment !== null) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['investment'], message: 'cash row cannot carry investment details' });
  }
  if (value.investment !== null && value.investment.currency !== 'EUR') {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['investment', 'currency'], message: 'manual ledger is EUR-only' });
  }
});
export type FinanceImportedRecord = z.infer<typeof FinanceImportedRecord>;

export const FinanceImportedUpsertOperation = z.object({
  operation: z.literal('upsert'),
  record: FinanceImportedRecord,
  /** Must match record.sourceRevision. Zero means create. */
  expectedSourceRevision: financeImportedRevision,
}).strict().superRefine((value, context) => {
  if (value.record.sourceRevision !== value.expectedSourceRevision) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['expectedSourceRevision'], message: 'source precondition must match record source revision' });
  }
});
export type FinanceImportedUpsertOperation = z.infer<typeof FinanceImportedUpsertOperation>;

export const FinanceImportedCategorySetOperation = z.object({
  operation: z.literal('categorySet'),
  recordID: z.string().uuid().transform(value => value.toLowerCase()),
  expectedSourceRevision: financeImportedRevision,
  categoryOverride: FinanceImportedCategory,
}).strict();
export type FinanceImportedCategorySetOperation = z.infer<typeof FinanceImportedCategorySetOperation>;

export const FinanceImportedCategoryClearOperation = z.object({
  operation: z.literal('categoryClear'),
  recordID: z.string().uuid().transform(value => value.toLowerCase()),
  expectedSourceRevision: financeImportedRevision,
}).strict();
export type FinanceImportedCategoryClearOperation = z.infer<typeof FinanceImportedCategoryClearOperation>;

export const FinanceImportedDeleteOperation = z.object({
  operation: z.literal('delete'),
  recordID: z.string().uuid().transform(value => value.toLowerCase()),
  expectedSourceRevision: financeImportedRevision,
  deletedAt: financeImportedTimestamp,
}).strict();
export type FinanceImportedDeleteOperation = z.infer<typeof FinanceImportedDeleteOperation>;

export const FinanceImportedRestoreOperation = z.object({
  operation: z.literal('restore'),
  record: FinanceImportedRecord,
  /** Restore is the only operation allowed to remove a tombstone. */
  expectedTombstoneRevision: financeImportedPositiveRevision,
}).strict().superRefine((value, context) => {
  if (value.record.sourceRevision !== 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['record', 'sourceRevision'], message: 'restore record must not carry a new authority revision' });
  }
});
export type FinanceImportedRestoreOperation = z.infer<typeof FinanceImportedRestoreOperation>;

export const FinanceImportedSyncOperation = z.union([
  FinanceImportedUpsertOperation,
  FinanceImportedCategorySetOperation,
  FinanceImportedCategoryClearOperation,
  FinanceImportedDeleteOperation,
  FinanceImportedRestoreOperation,
]);
export type FinanceImportedSyncOperation = z.infer<typeof FinanceImportedSyncOperation>;

export const FinanceImportedSyncRequest = z.object({
  schemaVersion: FinanceImportedSyncSchemaVersion,
  baseRevision: SyncRevision,
  operations: z.array(FinanceImportedSyncOperation).max(FINANCE_IMPORTED_MAX_OPERATIONS),
}).strict().superRefine((value, context) => {
  const ids = new Set<string>();
  value.operations.forEach((operation, index) => {
    const id = operation.operation === 'upsert' || operation.operation === 'restore'
      ? operation.record.recordID
      : operation.recordID;
    if (ids.has(id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['operations', index], message: 'duplicate record operation' });
    }
    ids.add(id);
  });
});
export type FinanceImportedSyncRequest = z.infer<typeof FinanceImportedSyncRequest>;

export const FinanceImportedTombstone = z.object({
  recordID: z.string().uuid().transform(value => value.toLowerCase()),
  revision: financeImportedPositiveRevision,
  deletedAt: financeImportedTimestamp,
}).strict();
export type FinanceImportedTombstone = z.infer<typeof FinanceImportedTombstone>;

export const FinanceImportedSyncSnapshot = z.object({
  schemaVersion: FinanceImportedSyncSchemaVersion,
  domain: FinanceImportedSyncDomain,
  ledger: FinanceImportedSyncLedger,
  authority: z.literal('gateway'),
  revision: SyncRevision,
  records: z.array(FinanceImportedRecord).max(FINANCE_IMPORTED_MAX_RECORDS),
  tombstones: z.array(FinanceImportedTombstone).max(FINANCE_IMPORTED_MAX_TOMBSTONES),
}).strict().superRefine((value, context) => {
  const recordIDs = new Set<string>();
  value.records.forEach((record, index) => {
    if (record.sourceRevision <= 0 || record.sourceRevision > value.revision) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['records', index, 'sourceRevision'], message: 'source revision must be positive and no newer than the snapshot' });
    }
    if (recordIDs.has(record.recordID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['records', index, 'recordID'], message: 'duplicate record id' });
    }
    recordIDs.add(record.recordID);
  });
  const tombstoneIDs = new Set<string>();
  value.tombstones.forEach((tombstone, index) => {
    if (tombstoneIDs.has(tombstone.recordID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'recordID'], message: 'duplicate tombstone id' });
    }
    if (recordIDs.has(tombstone.recordID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'recordID'], message: 'deleted record cannot remain live' });
    }
    if (tombstone.revision > value.revision) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['tombstones', index, 'revision'], message: 'tombstone revision exceeds snapshot revision' });
    }
    tombstoneIDs.add(tombstone.recordID);
  });
});
export type FinanceImportedSyncSnapshot = z.infer<typeof FinanceImportedSyncSnapshot>;

/** Canonical UTF-8 request encoding used by the native outbox and contract tests. */
function sortFinanceImportedJSON(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortFinanceImportedJSON);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0)
      .map(([key, child]) => [key, sortFinanceImportedJSON(child)]));
  }
  return value;
}

export function encodeFinanceImportedSyncRequest(value: unknown): Uint8Array {
  const parsed = FinanceImportedSyncRequest.parse(value);
  const encoded = new TextEncoder().encode(JSON.stringify(sortFinanceImportedJSON(parsed)));
  if (encoded.byteLength > FINANCE_IMPORTED_MAX_REQUEST_BYTES) {
    throw new Error('finance import request exceeds the UTF-8 byte cap');
  }
  return encoded;
}
