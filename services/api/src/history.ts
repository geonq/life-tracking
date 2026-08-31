import { createHash, randomUUID } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { TextDecoder } from 'node:util';
import { dirname, resolve } from 'node:path';
import { z } from 'zod';
import {
  UsageHistoryEntry,
  type UsageHistoryEntry as Entry,
} from '@iphone-life-os/contracts';
import { parseStrictJSON } from './json-boundary.js';
import { atomicWriteFile } from './atomic-file.js';

/** Keep malformed or unexpectedly large history files from causing an unbounded allocation. */
export const MAX_HISTORY_BYTES = 1 * 1024 * 1024;
export const MAX_HISTORY_METADATA_BYTES = 4 * 1024 * 1024;
export const MAX_HISTORY_STATE_BYTES = 6 * 1024 * 1024;
const HISTORY_STATE_SCHEMA_VERSION = 1;
const HISTORY_OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);
const MAX_SAFE_REVISION = Number.MAX_SAFE_INTEGER;

export type UsageHistoryErrorCode =
  | 'invalid_idempotency_key'
  | 'idempotency_key_reuse'
  | 'idempotency_store_full'
  | 'storage_unavailable';

export class UsageHistoryError extends Error {
  readonly code: UsageHistoryErrorCode;

  constructor(code: UsageHistoryErrorCode) {
    super(code);
    this.name = 'UsageHistoryError';
    this.code = code;
  }
}

export function isUsageIdempotencyKey(value: unknown): value is string {
  return typeof value === 'string' && /^[\x21-\x7e]{1,128}$/.test(value);
}

export type UsageHistoryWriteResult = {
  kind: 'accepted' | 'replay' | 'stale';
  revision: number;
};

type UsageState = {
  entries: Entry[];
  raw: Buffer;
  metadata: UsageMetadata;
};

type DurableUsageState = {
  schemaVersion: typeof HISTORY_STATE_SCHEMA_VERSION;
  rawBase64: string;
  metadata: UsageMetadata;
};

// Keep the API's durable sidecar in lockstep with SyncDomainMetadata from the
// shared contract. This local parser lets the standalone API package validate
// state even when a deployment has not yet regenerated the workspace package.
const UsageMetadata = z.object({
  schemaVersion: z.literal(1),
  domain: z.literal('usage'),
  authority: z.literal('api'),
  revision: z.number().finite().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  bodyDigest: z.string().regex(/^[0-9a-f]{64}$/),
  idempotency: z.array(z.object({
    key: z.string().regex(/^[\x21-\x7e]{1,128}$/),
    fingerprint: z.string().regex(/^[0-9a-f]{64}$/),
    revision: z.number().finite().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  }).strict()).max(10_000),
  // Usage samples are append-only telemetry in this service. A deletion
  // tombstone must not be silently accepted when no Usage delete operation
  // exists; an operator must migrate the authority contract first.
  tombstones: z.array(z.never()).max(10_000),
}).strict().superRefine((value, context) => {
  const keys = new Set<string>();
  value.idempotency.forEach((record, index) => {
    if (keys.has(record.key)) context.addIssue({ code: z.ZodIssueCode.custom, path: ['idempotency', index, 'key'], message: 'duplicate idempotency key' });
    if (record.revision > value.revision) context.addIssue({ code: z.ZodIssueCode.custom, path: ['idempotency', index, 'revision'], message: 'journal revision exceeds authority revision' });
    keys.add(record.key);
  });
});
type UsageMetadata = z.infer<typeof UsageMetadata>;

function digest(value: string | Buffer): string {
  return createHash('sha256').update(value).digest('hex');
}

function metadataFor(raw: Buffer, revision = 0): UsageMetadata {
  return UsageMetadata.parse({
    schemaVersion: 1,
    domain: 'usage',
    authority: 'api',
    revision,
    bodyDigest: digest(raw),
    idempotency: [],
    tombstones: [],
  });
}

function encodeEntries(entries: readonly Entry[]): Buffer {
  return Buffer.from(entries.map(entry => JSON.stringify(entry)).join('\n') + (entries.length ? '\n' : ''), 'utf8');
}

function idempotencyFingerprint(entries: readonly Entry[]): string {
  // An omitted capture timestamp is assigned by the API at receipt time. It
  // is transport metadata, not a new producer payload on retry, so it must not
  // turn one logical request into a key-reuse conflict.
  return digest(JSON.stringify(entries.map(({ observedAt: _observedAt, ...entry }) => entry)));
}

export class UsageHistory {
  private static readonly writeQueues = new Map<string, Promise<void>>();
  private readonly file: string;
  private readonly metadataFile: string;
  private readonly stateFile: string;

  constructor(
    file: string,
    private readonly maxSamples = 500,
    private readonly maxAgeMs = 30 * 24 * 60 * 60_000,
    /** Injected for deterministic retention tests; production defaults to the system clock. */
    private readonly now: () => number = () => Date.now(),
  ) {
    // history() creates a new instance per request, so the resolved path is the queue key.
    this.file = resolve(file);
    this.metadataFile = `${this.file}.meta.json`;
    this.stateFile = `${this.file}.state.json`;
  }

  async add(entry: Entry, idempotencyKey?: unknown): Promise<UsageHistoryWriteResult> {
    return this.addMany([entry], idempotencyKey);
  }

  async addMany(entries: readonly Entry[], idempotencyKey?: unknown): Promise<UsageHistoryWriteResult> {
    // Parse the complete batch before entering the queue: one invalid item cannot result in
    // a partial write of an otherwise valid batch.
    const safe = entries.map(entry => UsageHistoryEntry.parse(entry));
    if (idempotencyKey !== undefined && !isUsageIdempotencyKey(idempotencyKey)) {
      throw new UsageHistoryError('invalid_idempotency_key');
    }
    if (!safe.length) return { kind: 'accepted', revision: 0 };
    return this.enqueue(async () => {
      const state = await this.readState();
      const fingerprint = idempotencyFingerprint(safe);
      const previous = idempotencyKey === undefined
        ? undefined
        : state.metadata.idempotency.find(record => record.key === idempotencyKey);
      if (previous !== undefined) {
        if (previous.fingerprint !== fingerprint) throw new UsageHistoryError('idempotency_key_reuse');
        return { kind: 'replay', revision: state.metadata.revision };
      }
      if (idempotencyKey !== undefined && state.metadata.idempotency.length >= 10_000) {
        throw new UsageHistoryError('idempotency_store_full');
      }

      const nextEntries = [...state.entries];
      for (const incoming of safe) {
        const latest = nextEntries
          .filter(item => item.provider === incoming.provider && item.window === incoming.window)
          .reduce<Entry | undefined>((current, item) => !current || Date.parse(item.observedAt) > Date.parse(current.observedAt) ? item : current, undefined);
        const sameValues = latest?.usedPercent === incoming.usedPercent && latest?.resetAt === incoming.resetAt;
        // Replaying the same provider/window observation is always idempotent. A
        // statusline may be retried well after the previous request, so elapsed
        // time must not turn an identical observation into a duplicate sample.
        if (latest !== undefined && sameValues) continue;
        // A delayed collector retry must never become the apparent current
        // observation. This is deliberately per provider/window: a reset or a
        // changed value is useful only when it was captured after the latest
        // sample for that same quota window.
        if (latest !== undefined && Date.parse(incoming.observedAt) <= Date.parse(latest.observedAt)) continue;
        nextEntries.push(incoming);
      }

      // Retention is applied only after an accepted observation, preserving the
      // old no-op behavior for a replay through the compatibility API.
      const acceptedObservation = nextEntries.length !== state.entries.length;
      const retained = acceptedObservation
        ? nextEntries
          .filter(item => this.now() - Date.parse(item.observedAt) <= this.maxAgeMs)
          .sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt))
          .slice(-this.maxSamples)
        : state.entries;
      const nextRaw = acceptedObservation ? encodeEntries(retained) : state.raw;
      if (nextRaw.byteLength > MAX_HISTORY_BYTES) throw new UsageHistoryError('storage_unavailable');
      const bodyChanged = !nextRaw.equals(state.raw);
      if (bodyChanged && state.metadata.revision >= MAX_SAFE_REVISION) {
        throw new UsageHistoryError('storage_unavailable');
      }
      const revision = bodyChanged ? state.metadata.revision + 1 : state.metadata.revision;
      const nextMetadata = UsageMetadata.parse({
        ...state.metadata,
        revision,
        bodyDigest: digest(nextRaw),
        idempotency: idempotencyKey === undefined
          ? state.metadata.idempotency
          : [
            ...state.metadata.idempotency,
            { key: idempotencyKey, fingerprint, revision },
          ],
      });
      const metadataChanged = idempotencyKey !== undefined;
      if (!bodyChanged && !metadataChanged) return { kind: 'stale', revision };

      await this.persist(nextRaw, nextMetadata, bodyChanged);
      return { kind: bodyChanged ? 'accepted' : 'stale', revision };
    });
  }

  async list(provider?: Entry['provider'], durationMinutes?: number): Promise<Entry[]> {
    // A corrupt or unexpectedly replaced store is an availability failure,
    // not an empty history. Callers must preserve that distinction.
    const { entries } = await this.readState();
    return entries
      .filter(item => (!provider || item.provider === provider) && (!durationMinutes || item.durationMinutes === durationMinutes))
      .filter(item => this.now() - Date.parse(item.observedAt) <= this.maxAgeMs)
      .sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt))
      .slice(-this.maxSamples);
  }

  /** Read/validate the configured store without creating or replacing it. */
  async ready(): Promise<boolean> {
    try {
      await this.readState();
      return true;
    } catch {
      return false;
    }
  }

  /** Return the durable API-authority revision without creating state. */
  async currentRevision(): Promise<number> {
    return (await this.readState()).metadata.revision;
  }

  private async readState(): Promise<UsageState> {
    const durableState = await this.readBoundedFile(this.stateFile, MAX_HISTORY_STATE_BYTES);
    if (durableState !== undefined) return this.decodeDurableState(durableState);

    const raw = await this.readBoundedFile(this.file, MAX_HISTORY_BYTES);
    const metadataRaw = await this.readBoundedFile(this.metadataFile, MAX_HISTORY_METADATA_BYTES);
    if (raw === undefined && metadataRaw === undefined) {
      const empty = Buffer.alloc(0);
      return { entries: [], raw: empty, metadata: metadataFor(empty) };
    }
    if (raw === undefined && metadataRaw !== undefined) {
      throw new UsageHistoryError('storage_unavailable');
    }

    const body = raw ?? Buffer.alloc(0);
    const entries = this.decodeEntries(body);

    let metadata: UsageMetadata;
    if (metadataRaw === undefined) {
      // Pre-sidecar JSONL is a supported migration state. It has no replay
      // history and therefore starts at revision zero until the next keyed
      // mutation creates the durable metadata.
      metadata = metadataFor(body);
    } else {
      try {
        metadata = UsageMetadata.parse(parseStrictJSON(metadataRaw));
      } catch {
        throw new UsageHistoryError('storage_unavailable');
      }
      if (metadata.domain !== 'usage' || metadata.authority !== 'api' || metadata.bodyDigest !== digest(body)) {
        throw new UsageHistoryError('storage_unavailable');
      }
    }
    return { entries, raw: body, metadata };
  }

  private decodeEntries(body: Buffer): Entry[] {
    try {
      const text = new TextDecoder('utf-8', { fatal: true }).decode(body);
      return text.split(/\r?\n/).filter(Boolean).map(line => UsageHistoryEntry.parse(parseStrictJSON(line)));
    } catch {
      throw new UsageHistoryError('storage_unavailable');
    }
  }

  private decodeDurableState(body: Buffer): UsageState {
    try {
      const decoded = parseStrictJSON(body) as Partial<DurableUsageState> & Record<string, unknown>;
      if (Object.keys(decoded).length !== 3
        || decoded.schemaVersion !== HISTORY_STATE_SCHEMA_VERSION
        || typeof decoded.rawBase64 !== 'string'
        || decoded.metadata === undefined) throw new Error('invalid_usage_state');
      const raw = Buffer.from(decoded.rawBase64, 'base64');
      if (raw.length > MAX_HISTORY_BYTES || raw.toString('base64') !== decoded.rawBase64) {
        throw new Error('invalid_usage_state');
      }
      const metadata = UsageMetadata.parse(decoded.metadata);
      if (metadata.domain !== 'usage' || metadata.authority !== 'api' || metadata.bodyDigest !== digest(raw)) {
        throw new Error('invalid_usage_state');
      }
      return { entries: this.decodeEntries(raw), raw, metadata };
    } catch {
      throw new UsageHistoryError('storage_unavailable');
    }
  }

  private async readBoundedFile(path: string, maximum: number): Promise<Buffer | undefined> {
    let descriptor: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const before = await lstat(path);
      if (!before.isFile() || before.isSymbolicLink()
        || before.size > maximum) throw new Error('history_unavailable');
      descriptor = await open(path, HISTORY_OPEN_FLAGS);
      const opened = await descriptor.stat();
      if (!opened.isFile() || opened.isSymbolicLink()
        || opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size) {
        throw new Error('history_unavailable');
      }
      const buffer = Buffer.alloc(maximum + 1);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesRead } = await descriptor.read(buffer, offset, buffer.length - offset, offset);
        if (bytesRead === 0) break;
        offset += bytesRead;
      }
      const after = await descriptor.stat();
      if (!after.isFile() || after.isSymbolicLink()
        || after.dev !== before.dev || after.ino !== before.ino || after.size !== before.size
        || offset > maximum) throw new Error('history_unavailable');
      return Buffer.from(buffer.subarray(0, offset));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
      throw new UsageHistoryError('storage_unavailable');
    } finally {
      if (descriptor) await descriptor.close().catch(() => undefined);
    }
  }

  private async persist(raw: Buffer, metadata: UsageMetadata, bodyChanged: boolean): Promise<void> {
    const metadataBody = JSON.stringify(metadata);
    if (Buffer.byteLength(metadataBody, 'utf8') > MAX_HISTORY_METADATA_BYTES) {
      throw new UsageHistoryError('storage_unavailable');
    }
    const state: DurableUsageState = {
      schemaVersion: HISTORY_STATE_SCHEMA_VERSION,
      rawBase64: raw.toString('base64'),
      metadata,
    };
    const stateBody = JSON.stringify(state);
    if (Buffer.byteLength(stateBody, 'utf8') > MAX_HISTORY_STATE_BYTES) {
      throw new UsageHistoryError('storage_unavailable');
    }
    try {
      // The state envelope is the single commit point. The historical JSONL
      // and sidecar files remain compatibility projections; if a crash lands
      // between either projection rename, the next reader uses the complete
      // last state envelope and never observes a torn pair.
      await atomicWriteFile(this.stateFile, stateBody);
      await atomicWriteFile(this.metadataFile, metadataBody);
      if (bodyChanged) await atomicWriteFile(this.file, raw);
    } catch (error) {
      if (error instanceof UsageHistoryError) throw error;
      throw new UsageHistoryError('storage_unavailable');
    }
  }

  private enqueue<T>(task: () => Promise<T>): Promise<T> {
    const previous = UsageHistory.writeQueues.get(this.file) ?? Promise.resolve();
    let result!: T;
    const next = previous.catch(() => undefined).then(async () => {
      result = await task();
    });
    UsageHistory.writeQueues.set(this.file, next);
    return next.then(() => result).finally(() => {
      if (UsageHistory.writeQueues.get(this.file) === next) UsageHistory.writeQueues.delete(this.file);
    });
  }
}
