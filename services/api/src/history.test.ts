import { createHash } from 'node:crypto';
import { chmod, mkdir, mkdtemp, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { UsageHistoryEntry } from '@iphone-life-os/contracts';
import {
  assertStoragePathContract,
  atomicWriteFile,
  captureFilePathIdentityChain,
} from './atomic-file.js';
import {
  MAX_HISTORY_BATCH_ENTRIES,
  MAX_HISTORY_IDEMPOTENCY_RECORDS,
  MAX_HISTORY_QUEUE_DEPTH,
  MAX_HISTORY_SAMPLES,
  UsageHistory,
  UsageHistoryError,
} from './history.js';

const timestamp = (minute: number) => new Date(Date.UTC(2026, 0, 1, 0, minute)).toISOString();
const entry = (minute: number, usedPercent: number): UsageHistoryEntry => ({
  provider: 'codex',
  window: 'five_hour',
  durationMinutes: 300,
  usedPercent,
  observedAt: timestamp(minute),
});

function writeQueues(): Map<string, unknown> {
  return (UsageHistory as unknown as { writeQueues: Map<string, unknown> }).writeQueues;
}

describe('UsageHistory bounded mutation and retention behavior', () => {
  it('publishes an ordinary bounded file atomically and leaves no temporary entry', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-atomic-'));
    const file = join(directory, 'nested', 'state.json');

    await atomicWriteFile(file, JSON.stringify({ value: 'bounded' }));

    expect(await readFile(file, 'utf8')).toBe('{"value":"bounded"}');
    expect(await readdir(resolve(file, '..'))).toEqual(['state.json']);
  });

  it('fails readiness when an existing ancestor violates the protected storage contract', async () => {
    if (process.platform === 'win32') return;
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-contract-'));
    const storage = join(directory, 'storage');
    await mkdir(storage, { mode: 0o700 });
    await chmod(directory, 0o777);

    expect(await new UsageHistory(join(storage, 'history.jsonl')).ready()).toBe(false);
  });

  it('rejects an ancestor replacement against the captured path contract', async () => {
    if (process.platform === 'win32') return;
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-replacement-'));
    const storage = join(directory, 'storage');
    const displaced = join(directory, 'displaced-storage');
    await mkdir(storage, { mode: 0o700 });
    const captured = await captureFilePathIdentityChain(storage);
    await rename(storage, displaced);
    await mkdir(storage, { mode: 0o700 });

    await expect(assertStoragePathContract(storage, captured)).rejects.toThrow('path_changed');
    expect(await readdir(storage)).toEqual([]);
    expect(await readdir(displaced)).toEqual([]);
  });

  it('bounds concurrent work and releases queue bookkeeping after the drain completes', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-queue-'));
    const file = join(directory, 'nested', 'history.jsonl');
    const total = MAX_HISTORY_QUEUE_DEPTH + 8;
    const writes = Array.from({ length: total }, (_, minute) => new UsageHistory(
      file,
      total,
      3 * 60 * 60_000,
      () => Date.parse(timestamp(100)),
    ).add(entry(minute, minute)));

    const outcomes = await Promise.allSettled(writes);
    const fulfilled = outcomes.filter(outcome => outcome.status === 'fulfilled');
    const rejected = outcomes.filter(outcome => outcome.status === 'rejected');
    expect(fulfilled).toHaveLength(MAX_HISTORY_QUEUE_DEPTH);
    expect(rejected).toHaveLength(total - MAX_HISTORY_QUEUE_DEPTH);
    expect(rejected.every(outcome => outcome.status === 'rejected'
      && outcome.reason instanceof UsageHistoryError
      && outcome.reason.code === 'queue_full')).toBe(true);
    expect(writeQueues().has(resolve(file))).toBe(false);

    const store = new UsageHistory(file, total, 3 * 60 * 60_000, () => Date.parse(timestamp(100)));
    expect((await store.list()).map(item => item.usedPercent)).toEqual(
      Array.from({ length: MAX_HISTORY_QUEUE_DEPTH }, (_, minute) => minute),
    );
    await expect(store.add(entry(100, 99))).resolves.toMatchObject({ kind: 'accepted' });
    expect(writeQueues().has(resolve(file))).toBe(false);
  });

  it('rejects an oversized direct batch before creating durable state', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-batch-'));
    const file = join(directory, 'history.jsonl');
    const store = new UsageHistory(file, MAX_HISTORY_SAMPLES, 60 * 60_000, () => Date.parse(timestamp(2)));
    const entries = Array.from({ length: MAX_HISTORY_BATCH_ENTRIES + 1 }, (_, minute) => entry(minute, minute % 101));

    await expect(store.addMany(entries)).rejects.toMatchObject({ code: 'batch_too_large' });
    await expect(readFile(file)).rejects.toMatchObject({ code: 'ENOENT' });
    expect(writeQueues().has(resolve(file))).toBe(false);
  });

  it('leaves the last committed state readable when the durable idempotency bound is full', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-journal-'));
    const file = join(directory, 'history.jsonl');
    const statePath = `${file}.state.json`;
    const emptyDigest = createHash('sha256').update(Buffer.alloc(0)).digest('hex');
    const metadata = {
      schemaVersion: 1,
      domain: 'usage',
      authority: 'api',
      revision: 0,
      bodyDigest: emptyDigest,
      idempotency: Array.from({ length: MAX_HISTORY_IDEMPOTENCY_RECORDS }, (_, index) => ({
        key: `seed-${index}`,
        fingerprint: '0'.repeat(64),
        revision: 0,
      })),
      tombstones: [],
    };
    const committed = JSON.stringify({ schemaVersion: 1, rawBase64: '', metadata });
    await writeFile(statePath, committed, { encoding: 'utf8', mode: 0o600 });

    const store = new UsageHistory(file, 10, 60 * 60_000, () => Date.parse(timestamp(2)));
    await expect(store.add(entry(1, 10), 'new-key')).rejects.toMatchObject({ code: 'idempotency_store_full' });
    expect(await readFile(statePath, 'utf8')).toBe(committed);
    await expect(store.list()).resolves.toEqual([]);
    expect(await store.currentRevision()).toBe(0);
    expect(writeQueues().has(resolve(file))).toBe(false);
  });

  it('treats a zero sample limit as an empty bounded history', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-empty-'));
    const file = join(directory, 'history.jsonl');
    const store = new UsageHistory(file, 0, 60 * 60_000, () => Date.parse(timestamp(2)));

    await store.add(entry(1, 10));
    await expect(store.list()).resolves.toEqual([]);
    expect(() => new UsageHistory(file, MAX_HISTORY_SAMPLES + 1)).toThrow('invalid_history_sample_limit');
  });
});
