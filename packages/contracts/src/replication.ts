import { createHash } from 'node:crypto';
import { z } from 'zod';

export const SYNC_SCHEMA_VERSION = 1 as const;
export const MAX_PAGE_OPERATIONS = 128;
export const MAX_BODY_BYTES = 1_048_576;
export const MAX_INLINE_PAYLOAD_BYTES = 65_536;
export const MAX_BLOB_BYTES = 33_554_432;
export const MAX_BLOB_CHUNK_BYTES = 262_144;
export const MAX_ADMINISTRATIVE_SEGMENT_BYTES = 33_554_432;
export const MAX_ADMINISTRATIVE_BUNDLE_BYTES = 536_870_929;
export const MAX_ADMINISTRATIVE_MANIFEST_BYTES = 268_435_456;

const canonicalUUID = z.string().regex(
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  'lowercase canonical UUID required',
);
const hash = z.string().regex(/^[0-9a-f]{64}$/, 'lowercase SHA-256 required');
const unsigned = z.string().regex(/^(0|[1-9][0-9]*)$/, 'canonical unsigned decimal required');
const positiveUnsigned = unsigned.refine(value => value !== '0', 'positive unsigned decimal required');
const uint64Unsigned = unsigned.refine(
  value => BigInt(value) <= 18_446_744_073_709_551_615n,
  'unsigned decimal exceeds UInt64 range',
);
const positiveUInt64 = uint64Unsigned.refine(value => value !== '0', 'positive unsigned decimal required');
const administrativeSegmentBytes = uint64Unsigned.refine(
  value => BigInt(value) <= BigInt(MAX_ADMINISTRATIVE_SEGMENT_BYTES),
  'administrative segment exceeds cap',
);
const administrativeBundleBytes = uint64Unsigned.refine(
  value => BigInt(value) <= BigInt(MAX_ADMINISTRATIVE_BUNDLE_BYTES),
  'administrative bundle exceeds cap',
);
const administrativeManifestBytes = uint64Unsigned.refine(
  value => BigInt(value) <= BigInt(MAX_ADMINISTRATIVE_MANIFEST_BYTES),
  'administrative manifest exceeds cap',
);
const administrativeChunkLimit = z.string()
  .regex(/^(?:[1-9][0-9]{0,5})$/, 'positive canonical decimal required')
  .refine(value => BigInt(value) <= BigInt(MAX_BLOB_CHUNK_BYTES), 'chunk limit exceeds cap');
const base64URL = z.string().regex(/^(?:[A-Za-z0-9_-]{2,}|)$/, 'unpadded base64url required');
const publicKey = base64URL.refine(value => {
  try { return decodeBase64URL(value).byteLength === 32; } catch { return false; }
}, 'Ed25519 public key must be 32 bytes');
const signature = base64URL.refine(value => {
  try { return decodeBase64URL(value).byteLength === 64; } catch { return false; }
}, 'Ed25519 signature must be 64 bytes');
const nonce = base64URL.refine(value => {
  try { return decodeBase64URL(value).byteLength === 32; } catch { return false; }
}, 'nonce must be 32 bytes');
const schemaVersion = z.literal(SYNC_SCHEMA_VERSION);

export const SyncDomain = z.enum(['calendar', 'finance', 'fitness', 'planning', 'tax']);
export type SyncDomain = z.infer<typeof SyncDomain>;
export const SyncOperationKind = z.enum(['put', 'delete', 'resolve', 'bootstrap']);
export type SyncOperationKind = z.infer<typeof SyncOperationKind>;
export const SyncAckLevel = z.enum(['stored', 'applied', 'retainedConflict']);
export type SyncAckLevel = z.infer<typeof SyncAckLevel>;
export const SyncReplicaRole = z.enum(['applying', 'storing']);
export const SyncOutboxState = z.enum(['unsigned', 'ready', 'awaitingAcks', 'blocked']);
export const SyncErrorCode = z.enum([
  'invalidInput', 'hashMismatch', 'unauthenticated', 'revoked', 'replay',
  'missingParent', 'conflict', 'staleBase', 'membershipMismatch', 'idCollision',
  'capacity', 'unsupportedMedia', 'unsupportedSchema', 'busy', 'offline',
  'identityUnavailable', 'corruptStore', 'timedOut', 'diskFull', 'cancelled',
  'nonceMismatch', 'responseNonceMismatch', 'responseSignatureInvalid', 'responseReplay', 'responseEpochMismatch',
]);

export const SyncStream = z.object({
  storeID: canonicalUUID,
  originID: canonicalUUID,
}).strict();
export type SyncStream = z.infer<typeof SyncStream>;

export const SyncPosition = z.object({
  stream: SyncStream,
  through: unsigned,
}).strict();
export type SyncPosition = z.infer<typeof SyncPosition>;

export const SyncFrontier = z.object({
  schemaVersion,
  positions: z.array(SyncPosition).max(256),
}).strict().superRefine((value, context) => {
  const keys = value.positions.map(position => position.stream.storeID + '\0' + position.stream.originID);
  if (new Set(keys).size !== keys.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['positions'], message: 'duplicate stream' });
  }
  if (keys.some((key, index) => index > 0 && key <= keys[index - 1])) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['positions'], message: 'positions must be sorted' });
  }
});
export type SyncFrontier = z.infer<typeof SyncFrontier>;

export const SyncPayload = z.object({
  schemaVersion,
  hash,
  byteCount: z.number().int().nonnegative().max(MAX_BLOB_BYTES),
  inline: base64URL.nullable(),
  blobHash: hash.nullable(),
}).strict().superRefine((value, context) => {
  if ((value.inline === null) === (value.blobHash === null)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['inline'], message: 'exactly one payload representation is required' });
  }
  if (value.inline !== null) {
    let bytes: Buffer;
    try {
      bytes = decodeBase64URL(value.inline);
    } catch {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['inline'], message: 'invalid base64url' });
      return;
    }
    if (bytes.byteLength > MAX_INLINE_PAYLOAD_BYTES || bytes.byteLength !== value.byteCount) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['inline'], message: 'inline payload length mismatch' });
    }
    if (sha256Hex(bytes) !== value.hash) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['hash'], message: 'inline payload hash mismatch' });
    }
  }
  if (value.blobHash !== null && value.blobHash !== value.hash) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['blobHash'], message: 'blob hash must equal payload hash' });
  }
});
export type SyncPayload = z.infer<typeof SyncPayload>;

export const SyncOperation = z.object({
  schemaVersion,
  datasetID: canonicalUUID,
  epoch: positiveUnsigned,
  storeID: canonicalUUID,
  domain: SyncDomain,
  originID: canonicalUUID,
  keyID: hash,
  sequence: positiveUnsigned,
  mutationID: canonicalUUID,
  entityID: hash,
  parents: z.array(canonicalUUID).max(8),
  baseHash: hash.nullable(),
  kind: SyncOperationKind,
  payload: SyncPayload,
  signature,
}).strict().superRefine((value, context) => {
  const parents = [...value.parents].sort();
  if (parents.some((parent, index) => parent !== value.parents[index])
      || new Set(value.parents).size !== value.parents.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['parents'], message: 'parents must be sorted and unique' });
  }
  if (value.kind === 'delete' && value.payload.inline !== '') {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['payload'], message: 'delete payload must be empty inline bytes' });
  }
});
export type SyncOperation = z.infer<typeof SyncOperation>;

export const SyncAck = z.object({
  schemaVersion,
  datasetID: canonicalUUID,
  epoch: positiveUnsigned,
  storeID: canonicalUUID,
  mutationID: canonicalUUID,
  operationHash: hash,
  replicaID: canonicalUUID,
  keyID: hash,
  level: SyncAckLevel,
  resultHash: hash,
  signature,
}).strict();
export type SyncAck = z.infer<typeof SyncAck>;

export const SyncMember = z.object({
  deviceID: canonicalUUID,
  keyID: hash,
  publicKey,
  role: SyncReplicaRole,
  endpoint: z.string().url().max(253).nullable(),
}).strict();
export type SyncMember = z.infer<typeof SyncMember>;

export const SyncStoreDescriptor = z.object({
  storeID: canonicalUUID,
  domain: SyncDomain,
  kind: z.string().min(1).max(64),
  payloadVersion: z.number().int().min(1).max(65_535),
}).strict();
export type SyncStoreDescriptor = z.infer<typeof SyncStoreDescriptor>;

export const SyncMembership = z.object({
  schemaVersion,
  datasetID: canonicalUUID,
  epoch: positiveUnsigned,
  previousHash: hash.nullable(),
  ownerKeyID: hash,
  members: z.array(SyncMember).min(1).max(8),
  stores: z.array(SyncStoreDescriptor).min(1).max(32),
  signature,
}).strict();
export type SyncMembership = z.infer<typeof SyncMembership>;

export const SyncError = z.object({
  schemaVersion,
  code: SyncErrorCode,
  mutationID: canonicalUUID.nullable(),
  retryAfterSeconds: z.number().int().min(1).max(900).nullable(),
}).strict();
export type SyncError = z.infer<typeof SyncError>;

export const SyncOperationResult = z.object({
  mutationID: canonicalUUID,
  disposition: z.enum(['stored', 'alreadyStored', 'rejected']),
  error: SyncError.nullable(),
}).strict().superRefine((value, context) => {
  if (value.disposition === 'rejected' && value.error === null) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['error'], message: 'rejected result requires error' });
  }
  if (value.disposition !== 'rejected' && value.error !== null) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['error'], message: 'accepted result cannot carry error' });
  }
});
export type SyncOperationResult = z.infer<typeof SyncOperationResult>;

export const SyncExchangeRequest = z.object({
  schemaVersion,
  storeID: canonicalUUID,
  received: SyncFrontier,
  upper: SyncFrontier.nullable(),
  operations: z.array(SyncOperation).max(MAX_PAGE_OPERATIONS),
  acknowledgements: z.array(SyncAck).max(MAX_PAGE_OPERATIONS),
  limit: z.number().int().min(1).max(MAX_PAGE_OPERATIONS),
}).strict();
export type SyncExchangeRequest = z.infer<typeof SyncExchangeRequest>;

export const SyncExchangeResponse = z.object({
  schemaVersion,
  storeID: canonicalUUID,
  results: z.array(SyncOperationResult).max(MAX_PAGE_OPERATIONS),
  operations: z.array(SyncOperation).max(MAX_PAGE_OPERATIONS),
  acknowledgements: z.array(SyncAck).max(MAX_PAGE_OPERATIONS),
  upper: SyncFrontier,
  more: z.boolean(),
}).strict();
export type SyncExchangeResponse = z.infer<typeof SyncExchangeResponse>;

export const SyncSignedFrame = z.object({
  schemaVersion,
  datasetID: canonicalUUID,
  epoch: positiveUnsigned,
  endpointID: canonicalUUID,
  senderID: canonicalUUID,
  keyID: hash,
  requestID: canonicalUUID,
  nonce,
  method: z.literal('POST'),
  path: z.string().min(1).max(64),
  status: z.number().int().refine(value => value === 0 || (value >= 100 && value <= 599)),
  body: base64URL,
  bodyHash: hash,
  signature,
}).strict().superRefine((value, context) => {
  try {
    const body = decodeBase64URL(value.body);
    if (body.byteLength > MAX_BODY_BYTES || sha256Hex(body) !== value.bodyHash) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['bodyHash'], message: 'body hash or size invalid' });
    }
  } catch {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['body'], message: 'body is not canonical base64url' });
  }
});
export type SyncSignedFrame = z.infer<typeof SyncSignedFrame>;

export const LifeOSDataStoreID = z.enum([
  'calendar', 'financeImports', 'financeRecurring', 'financeInvestments',
  'financeBudgets', 'financeAllocations', 'financePreferences', 'financeTravel',
  'training', 'trainingTemplates', 'meals', 'nutritionGoals', 'supplements',
  'journal', 'lifestyle', 'barcodeRecords', 'planningJournal', 'planningFiles',
  'taxSanitized', 'taxRaw', 'usageLocal', 'clipperLocal', 'replicationTrust',
  'widgetSnapshot', 'nutritionPhotoOriginals', 'recoveryImports',
]);
export type LifeOSDataStoreID = z.infer<typeof LifeOSDataStoreID>;

export const AdminDataStoreID20 = z.enum(['usageLocal', 'clipperLocal']);
export type AdminDataStoreID20 = z.infer<typeof AdminDataStoreID20>;

export const AdminScope20 = z.object({
  namespace: z.literal('data.restore.v20'),
  datasetID: canonicalUUID,
  operationID: canonicalUUID,
  fenceID: canonicalUUID,
  targetHostID: canonicalUUID,
  storeID: AdminDataStoreID20,
}).strict();
export type AdminScope20 = z.infer<typeof AdminScope20>;

export const AdminBlobPut20 = z.object({
  schemaVersion: z.literal(20),
  scope: AdminScope20,
  blobHash: hash,
  totalBytes: administrativeSegmentBytes,
  offset: administrativeSegmentBytes,
  chunkHash: hash,
  bytesBase64URL: base64URL,
  isFinal: z.boolean(),
}).strict();
export type AdminBlobPut20 = z.infer<typeof AdminBlobPut20>;

export const AdminBlobPutResult20 = z.object({
  schemaVersion: z.literal(20),
  blobHash: hash,
  nextOffset: administrativeSegmentBytes,
  complete: z.boolean(),
}).strict();
export type AdminBlobPutResult20 = z.infer<typeof AdminBlobPutResult20>;

export const AdminBlobRead20 = z.object({
  schemaVersion: z.literal(20),
  scope: AdminScope20,
  blobHash: hash,
  offset: administrativeSegmentBytes,
  limit: administrativeChunkLimit,
}).strict();
export type AdminBlobRead20 = z.infer<typeof AdminBlobRead20>;

export const AdminBlobReadResult20 = z.object({
  schemaVersion: z.literal(20),
  blobHash: hash,
  totalBytes: administrativeSegmentBytes,
  offset: administrativeSegmentBytes,
  bytesBase64URL: base64URL,
  chunkHash: hash,
  isFinal: z.boolean(),
}).strict();
export type AdminBlobReadResult20 = z.infer<typeof AdminBlobReadResult20>;

export const RemotePackSource20 = z.object({
  schemaVersion: z.literal(20),
  namespace: z.literal('data.restore.v20'),
  datasetID: canonicalUUID,
  operationID: canonicalUUID,
  fenceID: canonicalUUID,
  targetHostID: canonicalUUID,
  storeID: AdminDataStoreID20,
  packHash: hash,
  sourceHash: hash,
  manifestFormat: z.enum(['packObjectV7', 'legacyPackV2']),
  manifestHash: hash,
  manifestByteCount: administrativeManifestBytes,
  bundleHash: hash,
  byteCount: administrativeBundleBytes,
  segments: z.array(z.object({
    index: z.number().int().min(0).max(65_535),
    blobHash: hash,
    byteCount: administrativeSegmentBytes,
  }).strict()).min(1).max(17),
}).strict();
export type RemotePackSource20 = z.infer<typeof RemotePackSource20>;

export const ObservationAccess20 = z.object({
  schemaVersion: z.literal(20),
  datasetID: canonicalUUID,
  epoch: positiveUInt64,
  originID: canonicalUUID,
  originKeyID: hash,
  readerKeyIDs: z.array(hash).max(8),
  ownerKeyID: hash,
  signature,
}).strict();
export type ObservationAccess20 = z.infer<typeof ObservationAccess20>;

export const SignedHealthObservation = z.object({
  schemaVersion: z.literal(1),
  datasetID: canonicalUUID,
  originID: canonicalUUID,
  keyID: hash,
  sequence: positiveUnsigned,
  body: base64URL.refine(value => {
    try { return decodeBase64URL(value).byteLength <= 131_072; } catch { return false; }
  }, 'observation body exceeds 128 KiB'),
  bodyHash: hash,
  signature,
}).strict().superRefine((value, context) => {
  try {
    const body = decodeBase64URL(value.body);
    if (sha256Hex(body) !== value.bodyHash) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['bodyHash'], message: 'observation body hash mismatch' });
    }
  } catch {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['body'], message: 'observation body is not canonical base64url' });
  }
});
export type SignedHealthObservation = z.infer<typeof SignedHealthObservation>;

export const ObservationPut20 = z.object({
  schemaVersion: z.literal(20),
  datasetID: canonicalUUID,
  observation: SignedHealthObservation,
}).strict();
export type ObservationPut20 = z.infer<typeof ObservationPut20>;

export const ObservationRead20 = z.object({
  schemaVersion: z.literal(20),
  datasetID: canonicalUUID,
  originID: canonicalUUID,
}).strict();
export type ObservationRead20 = z.infer<typeof ObservationRead20>;

export const ObservationResult20 = z.object({
  schemaVersion: z.literal(20),
  datasetID: canonicalUUID,
  originID: canonicalUUID,
  observation: SignedHealthObservation.nullable(),
}).strict();
export type ObservationResult20 = z.infer<typeof ObservationResult20>;

export const SyncHTTPEnvelopeV6 = z.object({
  schemaVersion: z.literal(6),
  tag: z.string().min(1).max(32),
  sessionID: canonicalUUID,
  requestID: canonicalUUID,
  requestNonce: nonce,
  epoch: unsigned,
  payload: z.unknown(),
}).strict();

export const SyncHTTPResponseEnvelopeV6 = SyncHTTPEnvelopeV6.extend({
  nextNonce: nonce,
});

export const SyncChallengeRequestV6 = z.object({
  datasetID: canonicalUUID,
  originID: canonicalUUID,
}).strict();
export const SyncChallengeResponseV6 = z.object({
  sessionID: canonicalUUID,
  nonce,
  expiresAt: z.number().int(),
}).strict();
export const SyncHelloRequestV6 = z.object({
  datasetID: canonicalUUID,
  originID: canonicalUUID,
  storeEncoding: z.string().min(1).max(64),
  aliasTableHash: hash,
  supportedSchemas: z.array(z.number().int().min(1).max(65_535)).min(1).max(32),
  capabilities: z.array(z.string().min(1).max(64)).max(64),
}).strict();
export const SyncHelloResponseV6 = z.object({
  sessionID: canonicalUUID,
  serverOriginID: canonicalUUID,
  epoch: positiveUnsigned,
  aliasTableHash: hash,
  expiresAt: z.number().int(),
  capabilities: z.array(z.string().min(1).max(64)).max(64),
}).strict();
export const SyncExchangeRequestV6 = z.object({
  streamID: canonicalUUID,
  after: SyncFrontier.nullable(),
  limit: z.number().int().min(1).max(64),
  submit: z.array(SyncOperation).max(64),
}).strict();
export const SyncOperationAdmissionV6 = z.object({
  operationHash: hash,
  mutationID: canonicalUUID,
  disposition: z.string().min(1).max(32),
  receiptID: canonicalUUID.nullable(),
}).strict();
export const SyncExchangeResponseV6 = z.object({
  accepted: z.array(SyncOperationAdmissionV6).max(64),
  operations: z.array(SyncOperation).max(128),
  next: SyncFrontier.nullable(),
  hasMore: z.boolean(),
}).strict();
export const SyncAckRequestV6 = z.object({ ack: SyncAck }).strict();
export const SyncAckResponseV6 = z.object({
  ack: SyncAck,
  acceptedAt: z.number().int(),
}).strict();
export const SyncBlobPutRequestV6 = z.object({
  storeID: canonicalUUID,
  blobHash: hash,
  totalBytes: positiveUnsigned,
  offset: unsigned,
  chunkHash: hash,
  bytesBase64URL: base64URL,
  isFinal: z.boolean(),
}).strict();
export const SyncBlobPutResponseV6 = z.object({
  blobHash: hash,
  nextOffset: unsigned,
  complete: z.boolean(),
}).strict();
export const SyncBlobReadRequestV6 = z.object({
  storeID: canonicalUUID,
  blobHash: hash,
  offset: unsigned,
  limit: z.number().int().min(1).max(MAX_BLOB_CHUNK_BYTES),
}).strict();
export const SyncBlobReadResponseV6 = z.object({
  blobHash: hash,
  offset: unsigned,
  bytesBase64URL: base64URL,
  chunkHash: hash,
  isFinal: z.boolean(),
}).strict();
export const SyncHealthResponseV6 = z.object({
  schemaVersion: z.literal(6),
  status: z.literal('ok'),
}).strict();

export function decodeBase64URL(value: string): Buffer {
  if (value.includes('=') || !/^[A-Za-z0-9_-]*$/.test(value)) throw new Error('invalid base64url');
  const padded = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
  const decoded = Buffer.from(padded, 'base64');
  if (decoded.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '') !== value) {
    throw new Error('non-canonical base64url');
  }
  return decoded;
}

export function sha256Hex(value: Uint8Array): string {
  return createHash('sha256').update(value).digest('hex');
}

type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

function canonicalValue(value: unknown): JSONValue {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return value;
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error('wire numbers must be non-negative integers');
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (typeof value === 'object') {
    const result: Record<string, JSONValue> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      result[key] = canonicalValue((value as Record<string, unknown>)[key]);
    }
    return result;
  }
  throw new Error('unsupported JSON value');
}

export function canonicalJSON(value: unknown): string {
  return JSON.stringify(canonicalValue(value));
}

function skipWhitespace(text: string, index: number): number {
  while (index < text.length && /[\u0009\u000a\u000d\u0020]/.test(text[index])) index += 1;
  return index;
}

function scanString(text: string, start: number): number {
  let index = start + 1;
  let escaped = false;
  while (index < text.length) {
    const code = text.charCodeAt(index);
    if (code < 0x20 && !escaped) throw new Error('control character in string');
    if (code === 0x22 && !escaped) return index + 1;
    if (code === 0x5c && !escaped) escaped = true;
    else escaped = false;
    index += 1;
  }
  throw new Error('unterminated string');
}

function scanValue(text: string, start: number, depth: number): number {
  if (depth > 32) throw new Error('JSON nesting too deep');
  let index = skipWhitespace(text, start);
  const first = text[index];
  if (first === '"') return scanString(text, index);
  if (first === '{') {
    index = skipWhitespace(text, index + 1);
    const keys = new Set<string>();
    if (text[index] === '}') return index + 1;
    while (true) {
      if (text[index] !== '"') throw new Error('object key required');
      const end = scanString(text, index);
      const key = JSON.parse(text.slice(index, end)) as string;
      if (keys.has(key)) throw new Error('duplicate object key');
      keys.add(key);
      index = skipWhitespace(text, end);
      if (text[index] !== ':') throw new Error('object colon required');
      index = skipWhitespace(text, scanValue(text, index + 1, depth + 1));
      if (text[index] === '}') return index + 1;
      if (text[index] !== ',') throw new Error('object comma required');
      index = skipWhitespace(text, index + 1);
    }
  }
  if (first === '[') {
    index = skipWhitespace(text, index + 1);
    if (text[index] === ']') return index + 1;
    while (true) {
      index = skipWhitespace(text, scanValue(text, index, depth + 1));
      if (text[index] === ']') return index + 1;
      if (text[index] !== ',') throw new Error('array comma required');
      index = skipWhitespace(text, index + 1);
    }
  }
  if (text.startsWith('true', index)) return index + 4;
  if (text.startsWith('false', index)) return index + 5;
  if (text.startsWith('null', index)) return index + 4;
  const number = text.slice(index).match(/^(?:0|[1-9][0-9]*)/);
  if (number) return index + number[0].length;
  throw new Error('invalid JSON value');
}

export function parseStrictJSON(text: string): unknown {
  if (Buffer.byteLength(text, 'utf8') > MAX_BODY_BYTES) throw new Error('body too large');
  const end = scanValue(text, 0, 0);
  if (skipWhitespace(text, end) !== text.length) throw new Error('trailing JSON');
  return JSON.parse(text);
}

export function parseSyncOperation(input: unknown): SyncOperation {
  return SyncOperation.parse(input);
}

export function operationSigningBytes(operation: SyncOperation): Uint8Array {
  const parsed = SyncOperation.parse(operation);
  const { signature: _signature, ...unsignedOperation } = parsed;
  const payload = Buffer.from(canonicalJSON(unsignedOperation), 'utf8');
  const domain = Buffer.from('LifeOS/operation/v1\0', 'utf8');
  const length = Buffer.allocUnsafe(4);
  length.writeUInt32BE(payload.byteLength, 0);
  return Buffer.concat([domain, length, payload]);
}

export function operationHash(operation: SyncOperation): string {
  return sha256Hex(operationSigningBytes(operation));
}

export function encodeSyncOperation(operation: SyncOperation): Uint8Array {
  const parsed = SyncOperation.parse(operation);
  return Buffer.from(canonicalJSON(parsed), 'utf8');
}

export function frameSigningBytes(frame: SyncSignedFrame): Uint8Array {
  const parsed = SyncSignedFrame.parse(frame);
  const { signature: _signature, ...unsignedFrame } = parsed;
  const payload = Buffer.from(canonicalJSON(unsignedFrame), 'utf8');
  const domain = Buffer.from('LifeOS/frame/v1\0', 'utf8');
  const length = Buffer.allocUnsafe(4);
  length.writeUInt32BE(payload.byteLength, 0);
  return Buffer.concat([domain, length, payload]);
}

export function parseAdminBlobPut(input: unknown): AdminBlobPut20 {
  return AdminBlobPut20.parse(input);
}

export function parseRemotePackSource(input: unknown): RemotePackSource20 {
  return RemotePackSource20.parse(input);
}
