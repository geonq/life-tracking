import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { resolve } from 'node:path';
import { ClipperSnapshot, parseClipperSnapshot, unavailableClipperSnapshot, type ClipperSnapshot as Snapshot } from '@iphone-life-os/contracts';
import { atomicWriteFile } from './atomic-file.js';
import { parseStrictJSON } from './json-boundary.js';

/** Keep a malformed Hermes payload from causing an unbounded allocation. */
export const CLIPPER_MAX_BYTES = 256 * 1024;
export const CLIPPER_STORE_SCHEMA_VERSION = 1;
export const MAX_CLIPPER_IDEMPOTENCY_RECORDS = 10_000;
export const MAX_CLIPPER_QUEUE_DEPTH = 64;

export type ClipperStoreErrorCode =
  | 'body_too_large'
  | 'invalid_json'
  | 'invalid_snapshot'
  | 'missing_idempotency_key'
  | 'invalid_idempotency_key'
  | 'idempotency_key_reuse'
  | 'idempotency_store_full'
  | 'queue_full'
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

type IdempotencyRecord = { key: string; fingerprint: string; revision: number };
type StoreEnvelope = {
  schemaVersion: typeof CLIPPER_STORE_SCHEMA_VERSION;
  snapshot: Snapshot;
  idempotency: IdempotencyRecord[];
  revision: number;
  tombstones: [];
};

type FileSignature = {
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
};

type DurableState = {
  snapshot: Snapshot | undefined;
  idempotency: Map<string, string>;
  idempotencyRevisions: Map<string, number>;
  revision: number;
  tombstones: [];
  bytes?: Buffer;
  signature?: FileSignature;
};

export type ClipperCommittedRead = {
  snapshot: Snapshot;
  revision: number;
};

type QueuedMutation = {
  task: () => Promise<unknown>;
  resolve: (value: unknown) => void;
  reject: (reason?: unknown) => void;
};

type MutationQueue = {
  pending: QueuedMutation[];
  running: boolean;
  size: number;
};

function inputByteLength(input: string | Buffer): number {
  return Buffer.isBuffer(input) ? input.byteLength : Buffer.byteLength(input, 'utf8');
}

function bytesFor(input: string | Buffer): Buffer {
  return Buffer.isBuffer(input) ? Buffer.from(input) : Buffer.from(input, 'utf8');
}

function cloneSnapshot(snapshot: Snapshot): Snapshot {
  // The store is an authority boundary. Never hand callers the object that is
  // also used for the next durable write; a caller-side mutation must not
  // change the advertised snapshot without a journaled ingest.
  return ClipperSnapshot.parse(JSON.parse(JSON.stringify(snapshot)));
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
  if (inputByteLength(input) > CLIPPER_MAX_BYTES) throw new ClipperStoreError('body_too_large');
  const bytes = bytesFor(input);
  const source = bytes.toString('utf8');
  let parsed: unknown;
  try {
    parsed = parseStrictJSON(bytes);
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
  static readonly maximumIdempotencyRecords = MAX_CLIPPER_IDEMPOTENCY_RECORDS;

  /**
   * Serialize the complete durable mutation, not just the final rename.
   * Separate ClipperStore instances can exist in one Node process; queueing
   * only a precomputed JSON body would let a later stale instance erase an
   * earlier idempotency record. The API deployment remains single-process;
   * cross-process locking is a separate deployment requirement.
   */
  private static readonly mutationQueues = new Map<string, MutationQueue>();
  private readonly file?: string;
  private readonly idempotency = new Map<string, string>();
  private readonly idempotencyRevisions = new Map<string, number>();
  private snapshot: Snapshot | undefined;
  private revision = 0;
  private tombstones: [] = [];
  private loaded = false;
  /** Invalidates detached reads when this instance starts or finishes a commit. */
  private loadGeneration = 0;

  constructor(file?: string) {
    this.file = file ? resolve(file) : undefined;
  }

  async readCommitted(): Promise<ClipperCommittedRead> {
    await this.load();
    return {
      snapshot: this.snapshot === undefined ? unavailableClipperSnapshot() : cloneSnapshot(this.snapshot),
      revision: this.revision,
    };
  }

  async get(): Promise<Snapshot> {
    return (await this.readCommitted()).snapshot;
  }

  /** Return the durable Clipper authority revision; missing state is revision zero. */
  async currentRevision(): Promise<number> {
    return (await this.readCommitted()).revision;
  }

  async ingest(idempotencyKey: unknown, input: string | Buffer): Promise<{ kind: 'accepted' | 'replay' | 'stale'; snapshot: Snapshot; revision: number }> {
    if (idempotencyKey === undefined) throw new ClipperStoreError('missing_idempotency_key');
    if (!isClipperIdempotencyKey(idempotencyKey)) throw new ClipperStoreError('invalid_idempotency_key');
    const parsed = parseSnapshot(input);

    if (this.file) {
      return this.enqueueMutation(async () => {
        // Re-read the authoritative envelope while holding the path lock so a
        // separate store instance cannot overwrite a newer journal entry.
        this.invalidateLoadedState();
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
  ): Promise<{ kind: 'accepted' | 'replay' | 'stale'; snapshot: Snapshot; revision: number }> {

    const fingerprint = createHash('sha256').update(parsed.bytes).digest('hex');
    const previous = this.idempotency.get(idempotencyKey);
    if (previous !== undefined) {
      if (previous !== fingerprint) throw new ClipperStoreError('idempotency_key_reuse');
      return {
        kind: 'replay',
        snapshot: this.snapshot === undefined ? cloneSnapshot(parsed.snapshot) : cloneSnapshot(this.snapshot),
        revision: this.revision,
      };
    }
    if (this.idempotency.size >= ClipperStore.maximumIdempotencyRecords) {
      throw new ClipperStoreError('idempotency_store_full');
    }

    const previousSnapshot = this.snapshot;
    const candidateIdempotency = new Map(this.idempotency);
    const candidateIdempotencyRevisions = new Map(this.idempotencyRevisions);
    candidateIdempotency.set(idempotencyKey, fingerprint);

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
      candidateIdempotencyRevisions.set(idempotencyKey, this.revision);
      const committed = await this.persistCandidate(previousSnapshot, candidateIdempotency, candidateIdempotencyRevisions, this.revision);
      const committedSnapshot = committed?.snapshot ?? previousSnapshot;
      const committedRevision = committed?.revision ?? this.revision;
      this.publishCommitted(committedSnapshot, candidateIdempotency, candidateIdempotencyRevisions, committedRevision);
      return { kind: 'stale', snapshot: cloneSnapshot(committedSnapshot), revision: committedRevision };
    }

    if (this.revision >= Number.MAX_SAFE_INTEGER) {
      throw new ClipperStoreError('storage_unavailable');
    }
    const candidateSnapshot = cloneSnapshot(parsed.snapshot);
    const candidateRevision = this.revision + 1;
    candidateIdempotencyRevisions.set(idempotencyKey, candidateRevision);
    // A candidate is detached from the live authority. Persisting and reading
    // it back is the commit boundary; only then may readers observe the new
    // snapshot and revision together.
    const committed = await this.persistCandidate(candidateSnapshot, candidateIdempotency, candidateIdempotencyRevisions, candidateRevision);
    const committedSnapshot = committed?.snapshot ?? candidateSnapshot;
    const committedRevision = committed?.revision ?? candidateRevision;
    this.publishCommitted(committedSnapshot, candidateIdempotency, candidateIdempotencyRevisions, committedRevision);
    return { kind: 'accepted', snapshot: cloneSnapshot(committedSnapshot), revision: committedRevision };
  }

  private async enqueueMutation<T>(operation: () => Promise<T>): Promise<T> {
    const key = this.file!;
    let queue = ClipperStore.mutationQueues.get(key);
    if (queue === undefined) {
      queue = { pending: [], running: false, size: 0 };
      ClipperStore.mutationQueues.set(key, queue);
    }
    if (queue.size >= MAX_CLIPPER_QUEUE_DEPTH) {
      throw new ClipperStoreError('queue_full');
    }

    queue.size += 1;
    const result = new Promise<T>((resolveResult, rejectResult) => {
      queue!.pending.push({
        task: operation as () => Promise<unknown>,
        resolve: resolveResult as (value: unknown) => void,
        reject: rejectResult,
      });
    });
    this.drainMutationQueue(key, queue);
    return result;
  }

  private drainMutationQueue(key: string, queue: MutationQueue): void {
    if (queue.running) return;
    queue.running = true;
    void (async () => {
      try {
        while (queue.pending.length > 0) {
          const operation = queue.pending.shift()!;
          try {
            operation.resolve(await operation.task());
          } catch (error) {
            operation.reject(error);
          } finally {
            queue.size -= 1;
          }
        }
      } finally {
        queue.running = false;
        if (queue.size === 0 && ClipperStore.mutationQueues.get(key) === queue) {
          ClipperStore.mutationQueues.delete(key);
        } else if (queue.pending.length > 0) {
          this.drainMutationQueue(key, queue);
        }
      }
    })();
  }

  private async load(): Promise<void> {
    if (this.loaded) return;
    // Read into detached state first. A read may overlap a mutation, and an
    // older read must never publish over a newer in-memory commit. The second
    // signature check also catches an atomic replacement by another store
    // instance before this read becomes authoritative.
    for (let attempt = 0; attempt < 4; attempt += 1) {
      if (this.loaded) return;
      const generation = this.loadGeneration;
      const state = await this.loadUnlocked();
      if (this.loaded || this.loadGeneration !== generation) continue;
      if (!(await this.fileStillMatches(state.signature))) continue;
      // The identity check is asynchronous. A mutation may invalidate this
      // detached load while it is awaiting lstat; never publish an older
      // envelope after that await without taking the generation gate again.
      if (this.loaded || this.loadGeneration !== generation) continue;
      this.publishLoaded(state);
      return;
    }
    this.loaded = false;
    throw new ClipperStoreError('storage_unavailable');
  }

  private invalidateLoadedState(): void {
    // Keep the last committed value available while the authoritative file is
    // being reloaded. Only a validated detached result may replace it.
    this.loaded = false;
    this.loadGeneration += 1;
  }

  private publishLoaded(state: DurableState): void {
    this.idempotency.clear();
    state.idempotency.forEach((fingerprint, key) => this.idempotency.set(key, fingerprint));
    this.idempotencyRevisions.clear();
    state.idempotencyRevisions.forEach((journalRevision, key) => this.idempotencyRevisions.set(key, journalRevision));
    this.snapshot = state.snapshot;
    this.revision = state.revision;
    this.tombstones = [];
    this.loaded = true;
  }

  private async fileStillMatches(signature: FileSignature | undefined): Promise<boolean> {
    if (!this.file) return true;
    try {
      const current = await lstat(this.file);
      if (signature === undefined) return false;
      return current.isFile() && !current.isSymbolicLink()
        && current.dev === signature.dev
        && current.ino === signature.ino
        && current.size === signature.size
        && current.mtimeMs === signature.mtimeMs;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT' && signature === undefined) return true;
      return false;
    }
  }

  private async loadUnlocked(): Promise<DurableState> {
    if (!this.file) {
      return {
        snapshot: undefined,
        idempotency: new Map(),
        idempotencyRevisions: new Map(),
        revision: 0,
        tombstones: [],
      };
    }
    let bytes: Buffer;
    let signature: FileSignature;
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
        || opened.dev !== metadata.dev || opened.ino !== metadata.ino || opened.size !== metadata.size
        || opened.mtimeMs !== metadata.mtimeMs) {
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
        || after.mtimeMs !== opened.mtimeMs
        || offset > CLIPPER_MAX_BYTES) throw new Error('unsafe_store');
      bytes = buffer.subarray(0, offset);
      signature = { dev: after.dev, ino: after.ino, size: after.size, mtimeMs: after.mtimeMs };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        return {
          snapshot: undefined,
          idempotency: new Map(),
          idempotencyRevisions: new Map(),
          revision: 0,
          tombstones: [],
        };
      }
      throw new ClipperStoreError('storage_unavailable');
    } finally {
      await descriptor?.close().catch(() => undefined);
    }
    try {
      const source = bytes.toString('utf8');
      const envelope = parseStrictJSON(bytes) as Partial<StoreEnvelope> & Record<string, unknown>;
      if (hasDuplicateObjectKeys(source)) throw new Error('duplicate_json_key');
      const keys = Object.keys(envelope);
      const commonEnvelope = keys.includes('schemaVersion') && keys.includes('snapshot') && keys.includes('idempotency');
      const legacyEnvelope = keys.length === 3 && commonEnvelope;
      const versionedEnvelope = keys.length === 5
        && commonEnvelope
        && keys.includes('revision') && keys.includes('tombstones');
      if ((!legacyEnvelope && !versionedEnvelope)
          || envelope.schemaVersion !== CLIPPER_STORE_SCHEMA_VERSION
          || !Array.isArray(envelope.idempotency)
          || envelope.snapshot === undefined) throw new Error('invalid_envelope');
      const durableRevision = legacyEnvelope && !versionedEnvelope ? 0 : envelope.revision;
      const tombstones = envelope.tombstones;
      if (typeof durableRevision !== 'number' || !Number.isSafeInteger(durableRevision) || durableRevision < 0
          || (versionedEnvelope && !Array.isArray(tombstones))
          || (versionedEnvelope && Array.isArray(tombstones) && tombstones.length !== 0)) throw new Error('invalid_envelope');
      const snapshot = ClipperSnapshot.parse(envelope.snapshot);
      const parsedJournal = new Map<string, string>();
      const parsedJournalRevisions = new Map<string, number>();
      for (const record of envelope.idempotency) {
        if (!record || typeof record !== 'object'
            || (Object.keys(record).length !== (legacyEnvelope && !versionedEnvelope ? 2 : 3))
            || !Object.hasOwn(record, 'key')
            || !Object.hasOwn(record, 'fingerprint')
            || !isClipperIdempotencyKey(record.key)
            || typeof record.fingerprint !== 'string'
            || !/^[0-9a-f]{64}$/.test(record.fingerprint)) throw new Error('invalid_journal');
        const journalRevision = legacyEnvelope && !versionedEnvelope ? 0 : record.revision;
        if (typeof journalRevision !== 'number' || !Number.isSafeInteger(journalRevision)
            || journalRevision < 0 || journalRevision > durableRevision) throw new Error('invalid_journal');
        if (parsedJournal.has(record.key)) throw new Error('duplicate_journal_key');
        parsedJournal.set(record.key, record.fingerprint);
        parsedJournalRevisions.set(record.key, journalRevision);
      }
      if (envelope.idempotency.length > ClipperStore.maximumIdempotencyRecords
        || parsedJournal.size > ClipperStore.maximumIdempotencyRecords) throw new Error('journal_full');
      return {
        snapshot,
        idempotency: parsedJournal,
        idempotencyRevisions: parsedJournalRevisions,
        revision: durableRevision,
        tombstones: [],
        bytes: Buffer.from(bytes),
        signature,
      };
    } catch {
      throw new ClipperStoreError('storage_unavailable');
    }
  }

  private publishCommitted(
    snapshot: Snapshot,
    idempotency: Map<string, string>,
    idempotencyRevisions: Map<string, number>,
    revision: number,
  ): void {
    this.loadGeneration += 1;
    this.idempotency.clear();
    idempotency.forEach((fingerprint, key) => this.idempotency.set(key, fingerprint));
    this.idempotencyRevisions.clear();
    idempotencyRevisions.forEach((journalRevision, key) => this.idempotencyRevisions.set(key, journalRevision));
    this.snapshot = snapshot;
    this.revision = revision;
    this.tombstones = [];
    this.loaded = true;
  }

  private async persistCandidate(
    snapshot: Snapshot,
    idempotency: Map<string, string>,
    idempotencyRevisions: Map<string, number>,
    revision: number,
  ): Promise<ClipperCommittedRead | undefined> {
    if (!this.file) return undefined;
    const envelope: StoreEnvelope = {
      schemaVersion: CLIPPER_STORE_SCHEMA_VERSION,
      snapshot,
      idempotency: [...idempotency].map(([key, fingerprint]) => ({
        key,
        fingerprint,
        revision: idempotencyRevisions.get(key) ?? revision,
      })),
      revision,
      tombstones: [],
    };
    if (idempotency.size > ClipperStore.maximumIdempotencyRecords) {
      throw new ClipperStoreError('idempotency_store_full');
    }
    const body = JSON.stringify(envelope);
    if (Buffer.byteLength(body, 'utf8') > CLIPPER_MAX_BYTES) {
      throw new ClipperStoreError('storage_unavailable');
    }
    try {
      await atomicWriteFile(this.file, body);
      // Verify the exact committed bytes through a detached reader before
      // publishing the live authority. This keeps a failed or externally
      // changed write from making the in-memory snapshot look newer than the
      // durable source.
      const committed = await new ClipperStore(this.file).loadUnlocked();
      // Compare the complete serialized envelope, including every journal
      // record and its revision. Checking only the dashboard snapshot lets a
      // truncated or concurrently replaced idempotency journal look committed
      // even though the next retry could be accepted twice.
      if (committed.bytes === undefined
        || !committed.bytes.equals(Buffer.from(body, 'utf8'))
        || committed.revision !== revision
        || committed.snapshot === undefined
        || JSON.stringify(committed.snapshot) !== JSON.stringify(snapshot)) {
        throw new Error('clipper_commit_readback_mismatch');
      }
      return { snapshot: cloneSnapshot(committed.snapshot), revision: committed.revision };
    } catch (error) {
      if (error instanceof ClipperStoreError) throw error;
      throw new ClipperStoreError('storage_unavailable');
    }
  }
}
