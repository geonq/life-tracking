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

async function writeFullJournal(file: string): Promise<void> {
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
  await writeFile(`${file}.state.json`, JSON.stringify({ schemaVersion: 1, rawBase64: '', metadata }), {
    encoding: 'utf8',
    mode: 0o600,
  });
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

  it('keeps a bounded replay window while retiring its oldest idempotency records', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-journal-'));
    const file = join(directory, 'history.jsonl');
    const statePath = `${file}.state.json`;
    await writeFullJournal(file);

    const store = new UsageHistory(file, 10, 60 * 60_000, () => Date.parse(timestamp(2)));
    await expect(store.add(entry(1, 10), 'new-key')).resolves.toMatchObject({ kind: 'accepted', revision: 1 });

    const acceptedState = JSON.parse(await readFile(statePath, 'utf8')) as {
      metadata: { idempotency: Array<{ key: string }> };
    };
    const acceptedKeys = acceptedState.metadata.idempotency.map(record => record.key);
    expect(acceptedState.metadata.idempotency).toHaveLength(MAX_HISTORY_IDEMPOTENCY_RECORDS);
    expect(acceptedKeys.slice(-2)).toEqual([`seed-${MAX_HISTORY_IDEMPOTENCY_RECORDS - 1}`, 'new-key']);
    expect(acceptedKeys).not.toContain('seed-0');

    const stateBeforeReplay = await readFile(statePath, 'utf8');
    await expect(store.add(entry(1, 10), 'new-key')).resolves.toMatchObject({ kind: 'replay', revision: 1 });
    expect(await readFile(statePath, 'utf8')).toBe(stateBeforeReplay);
    await expect(store.add(entry(1, 11), 'new-key')).rejects.toMatchObject({ code: 'idempotency_key_reuse' });
    expect(await readFile(statePath, 'utf8')).toBe(stateBeforeReplay);

    // seed-0 is outside the retained replay window, so it is accepted as a new
    // request and becomes the newest record under the same bounded journal.
    await expect(store.add(entry(2, 20), 'seed-0')).resolves.toMatchObject({ kind: 'accepted', revision: 2 });
    const retiredState = JSON.parse(await readFile(statePath, 'utf8')) as {
      metadata: { idempotency: Array<{ key: string }> };
    };
    const retiredKeys = retiredState.metadata.idempotency.map(record => record.key);
    expect(retiredState.metadata.idempotency.length).toBeLessThanOrEqual(MAX_HISTORY_IDEMPOTENCY_RECORDS);
    expect(retiredKeys).toContain('seed-0');
    expect(retiredKeys).not.toContain('seed-1');

    const reloaded = new UsageHistory(file, 10, 60 * 60_000, () => Date.parse(timestamp(2)));
    await expect(reloaded.currentRevision()).resolves.toBe(2);
    await expect(reloaded.list()).resolves.toEqual([entry(1, 10), entry(2, 20)]);
    await expect(reloaded.add(entry(2, 20), 'seed-0')).resolves.toMatchObject({ kind: 'replay', revision: 2 });
    expect(await readFile(statePath, 'utf8')).toBe(JSON.stringify(retiredState));
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
