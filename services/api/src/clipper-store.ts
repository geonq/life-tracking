import { createHash, randomUUID } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { lstat, mkdir, open, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { ClipperSnapshot, parseClipperSnapshot, unavailableClipperSnapshot, type ClipperSnapshot as Snapshot } from '@iphone-life-os/contracts';

/** Keep a malformed Hermes payload from causing an unbounded allocation. */
export const CLIPPER_MAX_BYTES = 1 * 1024 * 1024;
export const CLIPPER_STORE_SCHEMA_VERSION = 1;

export type ClipperStoreErrorCode =
  | 'body_too_large'
  | 'invalid_json'
  | 'invalid_snapshot'
  | 'missing_idempotency_key'
  | 'invalid_idempotency_key'
  | 'idempotency_key_reuse'
  | 'idempotency_store_full'
  | 'storage_unavailable';

export class ClipperStoreError extends Error {
  readonly code: ClipperStoreErrorCode;

  constructor(code: ClipperStoreErrorCode) {
    super(code);
    this.name = 'ClipperStoreError';
    this.code = code;
  }
}

export function isClipperIdempotencyKey(value: unknown): value is string {
  return typeof value === 'string' && /^[\x21-\x7e]{1,128}$/.test(value);
}

type IdempotencyRecord = { key: string; fingerprint: string };
type StoreEnvelope = {
  schemaVersion: typeof CLIPPER_STORE_SCHEMA_VERSION;
  snapshot: Snapshot;
  idempotency: IdempotencyRecord[];
};

function bytesFor(input: string | Buffer): Buffer {
  return Buffer.isBuffer(input) ? Buffer.from(input) : Buffer.from(input, 'utf8');
}

/**
 * JSON.parse deliberately keeps the last value for a repeated object key.
 * That is unsafe at an ingestion boundary because two producers can interpret
 * the same bytes differently. Scan the already-syntax-validated JSON and
 * compare decoded key values so escaped aliases such as `source` and
 * `sour\\u0063e` are duplicates too.
 */
function hasDuplicateObjectKeys(source: string): boolean {
  const stack: Array<Set<string> | undefined> = [];
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (character === '{') {
      stack.push(new Set());
      continue;
    }
    if (character === '[') {
      stack.push(undefined);
      continue;
    }
    if (character === '}' || character === ']') {
      stack.pop();
      continue;
    }
    if (character !== '"') continue;

    const start = index;
    index += 1;
    while (index < source.length) {
      if (source[index] === '\\') {
        index += 2;
        continue;
      }
      if (source[index] === '"') break;
      index += 1;
    }

    let cursor = index + 1;
    while (cursor < source.length && /\s/.test(source[cursor]!)) cursor += 1;
    const keys = stack.at(-1);
    if (source[cursor] !== ':' || keys === undefined) continue;
    const key = JSON.parse(source.slice(start, index + 1)) as string;
    if (keys.has(key)) return true;
    keys.add(key);
  }
  return false;
}

function parseSnapshot(input: string | Buffer): { snapshot: Snapshot; bytes: Buffer } {
  const bytes = bytesFor(input);
  if (bytes.byteLength > CLIPPER_MAX_BYTES) throw new ClipperStoreError('body_too_large');
  const source = bytes.toString('utf8');
  let parsed: unknown;
  try {
    parsed = JSON.parse(source);
    if (hasDuplicateObjectKeys(source)) throw new Error('duplicate_json_key');
  } catch {
    throw new ClipperStoreError('invalid_json');
  }
  let snapshot: Snapshot;
  try {
    snapshot = parseClipperSnapshot(parsed);
  } catch {
    throw new ClipperStoreError('invalid_snapshot');
  }
  // Hermes is an observed-data producer. It cannot clear a good snapshot by
  // posting the unavailable branch; unavailability is the read-side default.
  if (snapshot.availability !== 'observed') throw new ClipperStoreError('invalid_snapshot');
  return { snapshot, bytes };
}

function observationWatermark(snapshot: Snapshot): number {
  let latest = Number.NEGATIVE_INFINITY;
  const visit = (value: unknown): void => {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (typeof value !== 'object' || value === null) return;
    const record = value as Record<string, unknown>;
    if (typeof record.observedAt === 'string') {
      const timestamp = Date.parse(record.observedAt);
      if (Number.isFinite(timestamp)) latest = Math.max(latest, timestamp);
    }
    if (typeof record.at === 'string') {
      const timestamp = Date.parse(record.at);
      if (Number.isFinite(timestamp)) latest = Math.max(latest, timestamp);
    }
    Object.values(record).forEach(visit);
  };
  visit(snapshot);
  return latest;
}

/**
 * Durable local Clipper authority. A missing file is an honest unavailable
 * state. Existing files are validated before use and every accepted payload
 * is written atomically with its idempotency journal.
 */
export class ClipperStore {
  static readonly maximumIdempotencyRecords = 10_000;

  /**
   * Serialize the complete durable mutation, not just the final rename.
   * Separate ClipperStore instances can exist in one Node process; queueing
   * only a precomputed JSON body would let a later stale instance erase an
   * earlier idempotency record. The API deployment remains single-process;
   * cross-process locking is a separate deployment requirement.
   */
  private static readonly mutationQueues = new Map<string, Promise<void>>();
  private readonly file?: string;
  private readonly idempotency = new Map<string, string>();
  private snapshot: Snapshot | undefined;
  private loaded = false;

  constructor(file?: string) {
    this.file = file ? resolve(file) : undefined;
  }

  async get(): Promise<Snapshot> {
    await this.load();
    return this.snapshot ?? unavailableClipperSnapshot();
  }

  async ingest(idempotencyKey: unknown, input: string | Buffer): Promise<{ kind: 'accepted' | 'replay' | 'stale'; snapshot: Snapshot }> {
    if (idempotencyKey === undefined) throw new ClipperStoreError('missing_idempotency_key');
    if (!isClipperIdempotencyKey(idempotencyKey)) throw new ClipperStoreError('invalid_idempotency_key');
    const parsed = parseSnapshot(input);

    if (this.file) {
      return this.enqueueMutation(async () => {
        // Re-read the authoritative envelope while holding the path lock so a
        // separate store instance cannot overwrite a newer journal entry.
        this.loaded = false;
        this.snapshot = undefined;
        this.idempotency.clear();
        await this.load();
        return this.ingestLoaded(idempotencyKey, parsed);
      });
    }

    await this.load();
    return this.ingestLoaded(idempotencyKey, parsed);
  }

  private async ingestLoaded(
    idempotencyKey: string,
    parsed: { snapshot: Snapshot; bytes: Buffer },
  ): Promise<{ kind: 'accepted' | 'replay' | 'stale'; snapshot: Snapshot }> {

    const fingerprint = createHash('sha256').update(parsed.bytes).digest('hex');
    const previous = this.idempotency.get(idempotencyKey);
    if (previous !== undefined) {
      if (previous !== fingerprint) throw new ClipperStoreError('idempotency_key_reuse');
      return { kind: 'replay', snapshot: this.snapshot ?? parsed.snapshot };
    }
    if (this.idempotency.size >= ClipperStore.maximumIdempotencyRecords) {
      throw new ClipperStoreError('idempotency_store_full');
    }

    const previousSnapshot = this.snapshot;
    this.idempotency.set(idempotencyKey, fingerprint);

    // A collector can deliver an older capture after a newer one (for
    // example, when a retry was delayed by a provider or a worker restart).
    // Keep the idempotency journal entry so that retry remains a replay, but
    // never let the delayed observation become the current dashboard truth.
    // generatedAt is the producer's envelope time and can be newer than the
    // actual analytics capture after a delayed retry. Compare the newest
    // nested observedAt/at watermark instead, preserving source chronology.
    const incomingTime = observationWatermark(parsed.snapshot);
    const currentTime = previousSnapshot ? observationWatermark(previousSnapshot) : Number.NaN;
    if (previousSnapshot && Number.isFinite(incomingTime) && Number.isFinite(currentTime) && incomingTime <= currentTime) {
      try {
        await this.persistUnlocked();
      } catch (error) {
        this.idempotency.delete(idempotencyKey);
        throw error;
      }
      return { kind: 'stale', snapshot: previousSnapshot };
    }

    this.snapshot = parsed.snapshot;
    try {
      await this.persistUnlocked();
    } catch (error) {
      this.idempotency.delete(idempotencyKey);
      this.snapshot = previousSnapshot;
      throw error;
    }
    return { kind: 'accepted', snapshot: parsed.snapshot };
  }

  private async enqueueMutation<T>(operation: () => Promise<T>): Promise<T> {
    const key = this.file!;
    const previous = ClipperStore.mutationQueues.get(key) ?? Promise.resolve();
    let result!: T;
    const next = previous.catch(() => undefined).then(async () => {
      result = await operation();
    });
    ClipperStore.mutationQueues.set(key, next);
    try {
      await next;
      return result;
    } finally {
      if (ClipperStore.mutationQueues.get(key) === next) ClipperStore.mutationQueues.delete(key);
    }
  }

  private async load(): Promise<void> {
    if (this.loaded) return;
    try {
      await this.loadUnlocked();
      this.loaded = true;
    } catch (error) {
      // A transient read failure or corrupt envelope must not poison this
      // instance into returning an apparently clean unavailable state on the
      // next read. Keep retrying the real durable source, and keep surfacing
      // the typed failure until it is repaired.
      this.loaded = false;
      throw error;
    }
  }

  private async loadUnlocked(): Promise<void> {
    if (!this.file) return;
    let bytes: Buffer;
    let descriptor: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const metadata = await lstat(this.file);
      if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > CLIPPER_MAX_BYTES) {
        throw new Error('unsafe_store');
      }
      descriptor = await open(this.file, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0));
      const opened = await descriptor.stat();
      if (!opened.isFile() || opened.isSymbolicLink()
        || (process.platform !== 'win32' && (opened.mode & 0o077) !== 0)
        || opened.dev !== metadata.dev || opened.ino !== metadata.ino || opened.size !== metadata.size) {
        throw new Error('unsafe_store');
      }
      const buffer = Buffer.alloc(CLIPPER_MAX_BYTES + 1);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesRead } = await descriptor.read(buffer, offset, buffer.length - offset, offset);
        if (bytesRead === 0) break;
        offset += bytesRead;
      }
      const after = await descriptor.stat();
      if (!after.isFile() || after.isSymbolicLink()
        || after.dev !== metadata.dev || after.ino !== metadata.ino || after.size !== metadata.size
        || offset > CLIPPER_MAX_BYTES) throw new Error('unsafe_store');
      bytes = buffer.subarray(0, offset);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return;
      throw new ClipperStoreError('storage_unavailable');
    } finally {
      await descriptor?.close().catch(() => undefined);
    }
    try {
      const source = bytes.toString('utf8');
      const envelope = JSON.parse(source) as Partial<StoreEnvelope>;
      if (hasDuplicateObjectKeys(source)) throw new Error('duplicate_json_key');
      if (Object.keys(envelope).length !== 3
          || !Object.hasOwn(envelope, 'schemaVersion')
          || !Object.hasOwn(envelope, 'snapshot')
          || !Object.hasOwn(envelope, 'idempotency')
          || envelope.schemaVersion !== CLIPPER_STORE_SCHEMA_VERSION
          || !Array.isArray(envelope.idempotency)
          || envelope.snapshot === undefined) throw new Error('invalid_envelope');
      const snapshot = ClipperSnapshot.parse(envelope.snapshot);
      const parsedJournal = new Map<string, string>();
      for (const record of envelope.idempotency) {
        if (!record || typeof record !== 'object'
            || Object.keys(record).length !== 2
            || !Object.hasOwn(record, 'key')
            || !Object.hasOwn(record, 'fingerprint')
            || !isClipperIdempotencyKey(record.key)
            || typeof record.fingerprint !== 'string'
            || !/^[0-9a-f]{64}$/.test(record.fingerprint)) throw new Error('invalid_journal');
        if (parsedJournal.has(record.key)) throw new Error('duplicate_journal_key');
        parsedJournal.set(record.key, record.fingerprint);
      }
      if (parsedJournal.size > ClipperStore.maximumIdempotencyRecords) throw new Error('journal_full');
      this.idempotency.clear();
      parsedJournal.forEach((fingerprint, key) => this.idempotency.set(key, fingerprint));
      this.snapshot = snapshot;
    } catch {
      throw new ClipperStoreError('storage_unavailable');
    }
  }

  private async persistUnlocked(): Promise<void> {
    if (!this.file || !this.snapshot) return;
    const envelope: StoreEnvelope = {
      schemaVersion: CLIPPER_STORE_SCHEMA_VERSION,
      snapshot: this.snapshot,
      idempotency: [...this.idempotency].map(([key, fingerprint]) => ({ key, fingerprint })),
    };
    const body = JSON.stringify(envelope);
    if (Buffer.byteLength(body, 'utf8') > CLIPPER_MAX_BYTES) {
      throw new ClipperStoreError('storage_unavailable');
    }
    const directory = dirname(this.file);
    await mkdir(directory, { recursive: true });
    const temporary = `${this.file}.tmp-${process.pid}-${randomUUID()}`;
    try {
      await writeFile(temporary, body, { encoding: 'utf8', mode: 0o600 });
      await rename(temporary, this.file);
    } finally {
      await unlink(temporary).catch(() => undefined);
    }
  }
}
