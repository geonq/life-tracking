import { createHash } from 'node:crypto';

/** Calendar control/resource payloads are bounded to the frozen gateway limit. */
export const CALENDAR_MAX_BYTES = 256 * 1024;
export const CALENDAR_SCHEMA_VERSION = 1;

type JSONRecord = Record<string, unknown>;

export type CalendarDocument = JSONRecord & {
  schemaVersion: typeof CALENDAR_SCHEMA_VERSION;
  items: unknown[];
};

export type CalendarResource = {
  readonly document: CalendarDocument;
  readonly body: Buffer;
  readonly etag: string;
  readonly revision: number;
};

export type CalendarWriteResult = {
  readonly kind: 'accepted' | 'replay';
  readonly resource: CalendarResource;
};

export type CalendarStoreErrorCode =
  | 'body_too_large'
  | 'invalid_json'
  | 'invalid_resource'
  | 'missing_if_match'
  | 'invalid_if_match'
  | 'stale_revision'
  | 'missing_idempotency_key'
  | 'invalid_idempotency_key'
  | 'idempotency_key_reuse'
  | 'idempotency_store_full';

export class CalendarStoreError extends Error {
  readonly code: CalendarStoreErrorCode;

  constructor(code: CalendarStoreErrorCode) {
    super(code);
    this.name = 'CalendarStoreError';
    this.code = code;
  }
}

function isRecord(value: unknown): value is JSONRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseDocument(input: string | Buffer): { document: CalendarDocument; body: Buffer } {
  const bytes = Buffer.isBuffer(input) ? input : Buffer.from(input, 'utf8');
  if (bytes.byteLength > CALENDAR_MAX_BYTES) throw new CalendarStoreError('body_too_large');

  let parsed: unknown;
  try {
    parsed = JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new CalendarStoreError('invalid_json');
  }
  if (!isRecord(parsed) || parsed.schemaVersion !== CALENDAR_SCHEMA_VERSION || !Array.isArray(parsed.items)) {
    throw new CalendarStoreError('invalid_resource');
  }

  // Preserve the exact validated JSON bytes. The API is a dumb blob boundary;
  // changing object order/whitespace here could alter a client snapshot even
  // though it remains semantically equivalent JSON.
  return { document: parsed as CalendarDocument, body: Buffer.from(bytes) };
}

function resourceFor(document: CalendarDocument, body: Buffer, revision: number): CalendarResource {
  const digest = createHash('sha256').update(body).digest('hex');
  // Strong, deterministic, quoted ETag. Revision remains part of the tag even
  // when two accepted writes happen to contain identical bytes.
  const etag = `"calendar-v1-r${revision}-${digest}"`;
  return { document, body: Buffer.from(body), etag, revision };
}

function cloneResource(resource: CalendarResource): CalendarResource {
  return {
    document: resource.document,
    body: Buffer.from(resource.body),
    etag: resource.etag,
    revision: resource.revision,
  };
}

/** Validates only strong quoted tags emitted by this local Calendar store. */
export function isCalendarETag(value: unknown): value is string {
  return typeof value === 'string'
    && /^"calendar-v1-r\d+-[0-9a-f]{64}"$/.test(value);
}

/** Idempotency keys are opaque visible ASCII and never contain delimiters/control. */
export function isCalendarIdempotencyKey(value: unknown): value is string {
  return typeof value === 'string' && /^[\x21-\x7e]{1,128}$/.test(value);
}

type IdempotencyRecord = { fingerprint: string };

/**
 * Local, injectable Calendar authority foundation.
 *
 * This store is intentionally in-memory. It proves conditional revision and
 * replay behavior without pretending that the external Windows gateway or its
 * durable storage/identity boundary has been accepted.
 */
export class CalendarStore {
  static readonly maximumIdempotencyRecords = 10_000;

  private resource: CalendarResource;
  private readonly idempotency = new Map<string, IdempotencyRecord>();

  constructor(initialDocument: unknown = { schemaVersion: CALENDAR_SCHEMA_VERSION, items: [] }) {
    let encoded: string | undefined;
    try {
      encoded = JSON.stringify(initialDocument);
    } catch {
      throw new CalendarStoreError('invalid_resource');
    }
    if (encoded === undefined) throw new CalendarStoreError('invalid_resource');
    const parsed = parseDocument(encoded);
    this.resource = resourceFor(parsed.document, parsed.body, 0);
  }

  get(): CalendarResource {
    return cloneResource(this.resource);
  }

  put(ifMatch: unknown, idempotencyKey: unknown, input: string | Buffer): CalendarWriteResult {
    const parsed = parseDocument(input);
    if (ifMatch === undefined) throw new CalendarStoreError('missing_if_match');
    if (!isCalendarETag(ifMatch)) throw new CalendarStoreError('invalid_if_match');
    if (idempotencyKey === undefined) throw new CalendarStoreError('missing_idempotency_key');
    if (!isCalendarIdempotencyKey(idempotencyKey)) throw new CalendarStoreError('invalid_idempotency_key');

    const fingerprint = `${ifMatch}:${createHash('sha256').update(parsed.body).digest('hex')}`;
    const previous = this.idempotency.get(idempotencyKey);
    if (previous) {
      if (previous.fingerprint !== fingerprint) throw new CalendarStoreError('idempotency_key_reuse');
      // Replay is a no-op. Returning the current resource keeps the response
      // authoritative if another accepted writer advanced the store meanwhile.
      return { kind: 'replay', resource: this.get() };
    }

    if (ifMatch !== this.resource.etag) throw new CalendarStoreError('stale_revision');
    if (this.idempotency.size >= CalendarStore.maximumIdempotencyRecords) {
      throw new CalendarStoreError('idempotency_store_full');
    }

    this.idempotency.set(idempotencyKey, { fingerprint });
    this.resource = resourceFor(parsed.document, parsed.body, this.resource.revision + 1);
    return { kind: 'accepted', resource: this.get() };
  }
}
