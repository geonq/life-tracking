import { describe, expect, it } from 'vitest';
import { chmod, mkdtemp, readFile, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { CLIPPER_MAX_BYTES, ClipperStore, ClipperStoreError, MAX_CLIPPER_QUEUE_DEPTH } from './clipper-store.js';

const observedAt = new Date(Date.now() - 30_000).toISOString();
const provenance = {
  source: 'hermes-test-source', observedAt, freshness: 'fresh' as const,
  quality: 'observed' as const, connectorState: 'healthy' as const,
};
const metrics = {
  views: { availability: 'observed' as const, value: 100, provenance },
  subscribers: { availability: 'observed' as const, value: 10, provenance },
  revenue: { availability: 'observed' as const, amountCents: 2500, currency: 'EUR' as const, provenance },
};
const snapshot = {
  schemaVersion: 1,
  availability: 'observed' as const,
  generatedAt: observedAt,
  currency: 'EUR' as const,
  metrics,
  accounts: [],
  trends: [],
  breakdowns: [],
  provenance,
};

function mutationQueues(): Map<string, unknown> {
  return (ClipperStore as unknown as { mutationQueues: Map<string, unknown> }).mutationQueues;
}

describe('ClipperStore', () => {
  it('returns an honest unavailable state before the first Hermes observation', async () => {
    const result = await new ClipperStore().get();
    expect(result.availability).toBe('unavailable');
  });

  it('reports missing state as ready and rejects corrupt or unsafe existing state', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-readiness-'));
    const missingPath = join(directory, 'missing.json');
    const missing = new ClipperStore(missingPath);
    expect(await missing.ready()).toBe(true);
    expect((missing as unknown as { loaded: boolean }).loaded).toBe(false);

    const corruptPath = join(directory, 'corrupt.json');
    await writeFile(corruptPath, '{not-json', { mode: 0o600 });
    const corrupt = new ClipperStore(corruptPath);
    expect(await corrupt.ready()).toBe(false);
    expect((corrupt as unknown as { loaded: boolean }).loaded).toBe(false);

    const validPath = join(directory, 'valid.json');
    const writer = new ClipperStore(validPath);
    await writer.ingest('readiness-valid', JSON.stringify(snapshot));
    expect(await new ClipperStore(validPath).ready()).toBe(true);

    if (process.platform !== 'win32') {
      const linkedPath = join(directory, 'linked.json');
      await symlink(corruptPath, linkedPath);
      expect(await new ClipperStore(linkedPath).ready()).toBe(false);
    }
  });

  it('accepts observed snapshots, replays identical keys, and rejects key reuse', async () => {
    const store = new ClipperStore();
    const body = JSON.stringify(snapshot);
    const accepted = await store.ingest('hermes-1', body);
    expect(accepted.kind).toBe('accepted');
    expect(accepted.snapshot).toEqual(snapshot);

    const replay = await store.ingest('hermes-1', body);
    expect(replay.kind).toBe('replay');
    expect(replay.snapshot).toEqual(snapshot);
    await expect(store.ingest('hermes-1', JSON.stringify({ ...snapshot, generatedAt: observedAt }))).resolves.toMatchObject({ kind: 'replay' });
    await expect(store.ingest('hermes-1', JSON.stringify({ ...snapshot, metrics: { ...metrics, views: { ...metrics.views, value: 101 } } })))
      .rejects.toMatchObject({ code: 'idempotency_key_reuse' });
  });

  it('rejects unavailable snapshots and malformed idempotency keys', async () => {
    const store = new ClipperStore();
    await expect(store.ingest('key', JSON.stringify({
      schemaVersion: 1, availability: 'unavailable', generatedAt: observedAt,
      currency: 'EUR', provenance: {
        source: 'test', observedAt, freshness: 'unknown', quality: 'unavailable', connectorState: 'unavailable',
      },
    }))).rejects.toMatchObject({ code: 'invalid_snapshot' });
    await expect(store.ingest(undefined, JSON.stringify(snapshot))).rejects.toMatchObject({ code: 'missing_idempotency_key' });
    await expect(store.ingest('bad key', JSON.stringify(snapshot))).rejects.toMatchObject({ code: 'invalid_idempotency_key' });
  });

  it('rejects duplicate JSON keys, including escaped-equivalent provenance keys', async () => {
    const store = new ClipperStore();
    const duplicateTopLevel = JSON.stringify(snapshot).replace(
      '"availability":"observed"',
      '"availability":"unavailable","availability":"observed"',
    );
    const duplicateNested = JSON.stringify(snapshot).replace(
      '"source":"hermes-test-source"',
      '"source":"untrusted","sour\\u0063e":"hermes-test-source"',
    );

    await expect(store.ingest('duplicate-top-level', duplicateTopLevel))
      .rejects.toMatchObject({ code: 'invalid_json' });
    await expect(store.ingest('duplicate-nested', duplicateNested))
      .rejects.toMatchObject({ code: 'invalid_json' });
    expect((await store.get()).availability).toBe('unavailable');
  });

  it('persists the latest snapshot and the idempotency journal across reload', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-store-'));
    const path = join(directory, 'clipper-snapshot.json');
    const body = JSON.stringify(snapshot);
    const first = new ClipperStore(path);
    await first.ingest('persistent-key', body);

    const persisted = JSON.parse(await readFile(path, 'utf8'));
    expect(persisted.schemaVersion).toBe(1);
    expect(persisted.snapshot).toEqual(snapshot);
    expect(persisted.revision).toBe(1);
    expect(persisted.tombstones).toEqual([]);
    expect(persisted.idempotency).toEqual([
      { key: 'persistent-key', fingerprint: expect.stringMatching(/^[0-9a-f]{64}$/), revision: 1 },
    ]);

    const reloaded = new ClipperStore(path);
    expect(await reloaded.get()).toEqual(snapshot);
    await expect(reloaded.ingest('persistent-key', body)).resolves.toMatchObject({ kind: 'replay' });
  });

  it('does not expose mutable authority state through reads or replay responses', async () => {
    const store = new ClipperStore();
    const body = JSON.stringify(snapshot);
    await store.ingest('detached-key', body);

    const exposed = await store.get();
    if (exposed.availability !== 'observed') throw new Error('expected observed snapshot');
    exposed.metrics.views.value = 999;
    expect((await store.get()).metrics.views.value).toBe(100);

    const replay = await store.ingest('detached-key', body);
    if (replay.snapshot.availability !== 'observed') throw new Error('expected observed replay');
    expect(replay.snapshot.metrics.views.value).toBe(100);
  });

  it('does not lose the journal when separate store instances ingest concurrently', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-concurrent-'));
    const path = join(directory, 'clipper-snapshot.json');
    const body = JSON.stringify(snapshot);
    const [first, second] = await Promise.all([
      new ClipperStore(path).ingest('concurrent-one', body),
      new ClipperStore(path).ingest('concurrent-two', body),
    ]);
    expect(first.kind).toBe('accepted');
    expect(second.kind).toBe('stale');
    const reloaded = new ClipperStore(path);
    await expect(reloaded.ingest('concurrent-one', body)).resolves.toMatchObject({ kind: 'replay' });
    await expect(reloaded.ingest('concurrent-two', body)).resolves.toMatchObject({ kind: 'replay' });
  });

  it('does not let an overlapping old read overwrite a committed ingest', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-read-race-'));
    const path = join(directory, 'clipper-snapshot.json');
    const store = new ClipperStore(path);
    await store.ingest('read-race-initial', JSON.stringify(snapshot));

    const newerAt = new Date().toISOString();
    const newer = {
      ...snapshot,
      generatedAt: newerAt,
      provenance: { ...snapshot.provenance, observedAt: newerAt },
      metrics: Object.fromEntries(Object.entries(snapshot.metrics).map(([key, metric]) => [
        key,
        { ...metric, provenance: { ...metric.provenance, observedAt: newerAt } },
      ])),
    };
    const internals = store as unknown as {
      loadUnlocked: () => Promise<unknown>;
      loaded: boolean;
    };
    const originalLoad = internals.loadUnlocked.bind(store);
    let entered!: () => void;
    const enteredPromise = new Promise<void>(resolveEntered => { entered = resolveEntered; });
    let release!: () => void;
    const releasePromise = new Promise<void>(resolveRelease => { release = resolveRelease; });
    let calls = 0;
    internals.loadUnlocked = async () => {
      const detached = await originalLoad();
      calls += 1;
      if (calls === 1) {
        entered();
        await releasePromise;
      }
      return detached;
    };

    // Start a durable reload and hold the detached old envelope after it has
    // been read. The following ingest must be able to commit before that read
    // is allowed to publish.
    internals.loaded = false;
    const pendingRead = store.readCommitted();
    await enteredPromise;
    const pendingIngest = store.ingest('read-race-new', JSON.stringify(newer));
    await expect(pendingIngest).resolves.toMatchObject({ kind: 'accepted', snapshot: newer, revision: 2 });
    release();

    await expect(pendingRead).resolves.toMatchObject({ snapshot: newer, revision: 2 });
    await expect(store.readCommitted()).resolves.toMatchObject({ snapshot: newer, revision: 2 });
  });

  it('rechecks the generation after a delayed file identity check', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-file-check-race-'));
    const path = join(directory, 'clipper-snapshot.json');
    const store = new ClipperStore(path);
    await store.ingest('file-check-initial', JSON.stringify(snapshot));

    const newerAt = new Date().toISOString();
    const newer = {
      ...snapshot,
      generatedAt: newerAt,
      provenance: { ...snapshot.provenance, observedAt: newerAt },
      metrics: Object.fromEntries(Object.entries(snapshot.metrics).map(([key, metric]) => [
        key,
        { ...metric, provenance: { ...metric.provenance, observedAt: newerAt } },
      ])),
    };
    const internals = store as unknown as {
      fileStillMatches: (signature: unknown) => Promise<boolean>;
      loaded: boolean;
    };
    const originalFileStillMatches = internals.fileStillMatches.bind(store);
    let entered!: () => void;
    const enteredPromise = new Promise<void>(resolveEntered => { entered = resolveEntered; });
    let release!: () => void;
    const releasePromise = new Promise<void>(resolveRelease => { release = resolveRelease; });
    let calls = 0;
    internals.fileStillMatches = async signature => {
      calls += 1;
      if (calls === 1) {
        entered();
        await releasePromise;
      }
      return originalFileStillMatches(signature);
    };

    internals.loaded = false;
    const pendingRead = store.readCommitted();
    await enteredPromise;

    await expect(store.ingest('file-check-new', JSON.stringify(newer)))
      .resolves.toMatchObject({ kind: 'accepted', snapshot: newer, revision: 2 });
    release();

    // The delayed old read must retry and return the newer committed state.
    await expect(pendingRead).resolves.toMatchObject({ snapshot: newer, revision: 2 });
    await expect(store.readCommitted()).resolves.toMatchObject({ snapshot: newer, revision: 2 });
    const persisted = JSON.parse(await readFile(path, 'utf8'));
    expect(persisted.revision).toBe(2);
    expect(persisted.snapshot).toEqual(newer);
    expect(persisted.idempotency.map((entry: { key: string }) => entry.key)).toEqual([
      'file-check-initial', 'file-check-new',
    ]);
  });

  it('keeps the last committed snapshot and revision visible until a delayed write commits', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-commit-boundary-'));
    const path = join(directory, 'clipper-snapshot.json');
    const first = new ClipperStore(path);
    await first.ingest('committed-one', JSON.stringify(snapshot));
    const newerAt = new Date().toISOString();
    const newer = {
      ...snapshot,
      generatedAt: newerAt,
      provenance: { ...snapshot.provenance, observedAt: newerAt },
      metrics: Object.fromEntries(Object.entries(snapshot.metrics).map(([key, metric]) => [
        key,
        { ...metric, provenance: { ...metric.provenance, observedAt: newerAt } },
      ])),
    };

    const internals = first as unknown as {
      persistCandidate: (...args: unknown[]) => Promise<unknown>;
    };
    const originalPersist = internals.persistCandidate.bind(first);
    let entered!: () => void;
    const enteredPromise = new Promise<void>(resolveEntered => { entered = resolveEntered; });
    let release!: () => void;
    const releasePromise = new Promise<void>(resolveRelease => { release = resolveRelease; });
    internals.persistCandidate = async (...args: unknown[]) => {
      entered();
      await releasePromise;
      return originalPersist(...args);
    };

    const pending = first.ingest('committed-two', JSON.stringify(newer));
    await enteredPromise;
    await expect(first.readCommitted()).resolves.toMatchObject({ snapshot, revision: 1 });
    expect(JSON.parse(await readFile(path, 'utf8')).revision).toBe(1);
    release();
    await expect(pending).resolves.toMatchObject({ kind: 'accepted', snapshot: newer, revision: 2 });
    await expect(first.readCommitted()).resolves.toMatchObject({ snapshot: newer, revision: 2 });
  });

  it('does not publish a candidate when persistence fails after a delay', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-commit-failure-'));
    const path = join(directory, 'clipper-snapshot.json');
    const store = new ClipperStore(path);
    await store.ingest('failure-one', JSON.stringify(snapshot));
    const internals = store as unknown as {
      persistCandidate: (...args: unknown[]) => Promise<unknown>;
    };
    let entered!: () => void;
    const enteredPromise = new Promise<void>(resolveEntered => { entered = resolveEntered; });
    let release!: () => void;
    const releasePromise = new Promise<void>(resolveRelease => { release = resolveRelease; });
    internals.persistCandidate = async () => {
      entered();
      await releasePromise;
      throw new ClipperStoreError('storage_unavailable');
    };

    const pending = store.ingest('failure-two', JSON.stringify({ ...snapshot, generatedAt: new Date().toISOString() }));
    await enteredPromise;
    await expect(store.readCommitted()).resolves.toMatchObject({ snapshot, revision: 1 });
    release();
    await expect(pending).rejects.toMatchObject({ code: 'storage_unavailable' });
    await expect(store.readCommitted()).resolves.toMatchObject({ snapshot, revision: 1 });
    expect(JSON.parse(await readFile(path, 'utf8')).revision).toBe(1);
  });

  it('bounds concurrent mutations and releases path bookkeeping after the drain completes', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-queue-'));
    const path = join(directory, 'clipper-snapshot.json');
    const body = JSON.stringify(snapshot);
    const total = MAX_CLIPPER_QUEUE_DEPTH + 8;
    const ingests = Array.from({ length: total }, (_, index) => new ClipperStore(path).ingest(`bounded-${index}`, body));

    const outcomes = await Promise.allSettled(ingests);
    const fulfilled = outcomes.filter(outcome => outcome.status === 'fulfilled');
    const rejected = outcomes.filter(outcome => outcome.status === 'rejected');
    expect(fulfilled).toHaveLength(MAX_CLIPPER_QUEUE_DEPTH);
    expect(rejected).toHaveLength(total - MAX_CLIPPER_QUEUE_DEPTH);
    expect(rejected.every(outcome => outcome.status === 'rejected'
      && outcome.reason instanceof ClipperStoreError
      && outcome.reason.code === 'queue_full')).toBe(true);
    expect(mutationQueues().has(resolve(path))).toBe(false);

    const persisted = JSON.parse(await readFile(path, 'utf8'));
    expect(persisted.idempotency).toHaveLength(MAX_CLIPPER_QUEUE_DEPTH);
    await expect(new ClipperStore(path).ingest('after-bound', body)).resolves.toMatchObject({ kind: 'stale' });
    expect(mutationQueues().has(resolve(path))).toBe(false);
  });

  it('rejects an oversized direct payload before creating durable state', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-body-'));
    const path = join(directory, 'clipper-snapshot.json');

    await expect(new ClipperStore(path).ingest('oversized', 'x'.repeat(CLIPPER_MAX_BYTES + 1)))
      .rejects.toMatchObject({ code: 'body_too_large' });
    await expect(readFile(path)).rejects.toMatchObject({ code: 'ENOENT' });
  });

  it('keeps the last committed snapshot readable when the serialized durable envelope exceeds its bound', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-durable-bound-'));
    const path = join(directory, 'clipper-snapshot.json');
    const point = { at: observedAt, metrics };
    const trends: Array<{ at: string; metrics: typeof metrics }> = [];
    let body = JSON.stringify({ ...snapshot, trends });
    while (true) {
      const candidate = JSON.stringify({ ...snapshot, trends: [...trends, point] });
      if (Buffer.byteLength(candidate, 'utf8') > CLIPPER_MAX_BYTES - 64) break;
      trends.push(point);
      body = candidate;
    }
    const envelope = {
      schemaVersion: 1,
      snapshot: JSON.parse(body),
      idempotency: [{ key: 'large-envelope', fingerprint: '0'.repeat(64), revision: 1 }],
      revision: 1,
      tombstones: [],
    };
    expect(Buffer.byteLength(body, 'utf8')).toBeLessThanOrEqual(CLIPPER_MAX_BYTES);
    expect(Buffer.byteLength(JSON.stringify(envelope), 'utf8')).toBeGreaterThan(CLIPPER_MAX_BYTES);

    await expect(new ClipperStore(path).ingest('large-envelope', body))
      .rejects.toMatchObject({ code: 'storage_unavailable' });
    await expect(new ClipperStore(path).get()).resolves.toMatchObject({ availability: 'unavailable' });
    await expect(readFile(path)).rejects.toMatchObject({ code: 'ENOENT' });
  });

  it('journals but does not publish an older observation after a newer one', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-monotonic-'));
    const path = join(directory, 'clipper-snapshot.json');
    const newerAt = new Date(Date.now() - 10_000).toISOString();
    const olderAt = new Date(Date.now() - 20_000).toISOString();
    const withObservationTime = (at: string) => ({
      ...snapshot,
      generatedAt: at,
      metrics: {
        views: { ...snapshot.metrics.views, provenance: { ...provenance, observedAt: at } },
        subscribers: { ...snapshot.metrics.subscribers, provenance: { ...provenance, observedAt: at } },
        revenue: { ...snapshot.metrics.revenue, provenance: { ...provenance, observedAt: at } },
      },
      provenance: { ...provenance, observedAt: at },
    });
    const newer = withObservationTime(newerAt);
    const older = withObservationTime(olderAt);
    const store = new ClipperStore(path);
    await expect(store.ingest('newer', JSON.stringify(newer))).resolves.toMatchObject({ kind: 'accepted' });
    await expect(store.ingest('older', JSON.stringify(older))).resolves.toMatchObject({ kind: 'stale', snapshot: newer });
    await expect(new ClipperStore(path).ingest('older', JSON.stringify(older))).resolves.toMatchObject({ kind: 'replay', snapshot: newer });
    expect(await new ClipperStore(path).get()).toEqual(newer);
  });

  it('uses nested observation time when an envelope is regenerated after capture', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-watermark-'));
    const path = join(directory, 'clipper-snapshot.json');
    const current = Date.now();
    const newerObservedAt = new Date(current - 10_000).toISOString();
    const olderObservedAt = new Date(current - 20_000).toISOString();
    const withObservation = (generatedAt: string, observed: string) => ({
      ...snapshot,
      generatedAt,
      metrics: {
        views: { ...snapshot.metrics.views, provenance: { ...provenance, observedAt: observed } },
        subscribers: { ...snapshot.metrics.subscribers, provenance: { ...provenance, observedAt: observed } },
        revenue: { ...snapshot.metrics.revenue, provenance: { ...provenance, observedAt: observed } },
      },
      provenance: { ...provenance, observedAt: observed },
    });
    const newer = withObservation(newerObservedAt, newerObservedAt);
    const delayedEnvelope = withObservation(new Date(current).toISOString(), olderObservedAt);
    const store = new ClipperStore(path);
    await expect(store.ingest('capture-newer', JSON.stringify(newer))).resolves.toMatchObject({ kind: 'accepted' });
    await expect(store.ingest('delayed-envelope', JSON.stringify(delayedEnvelope)))
      .resolves.toMatchObject({ kind: 'stale', snapshot: newer });
    expect(await new ClipperStore(path).get()).toEqual(newer);
  });

  it('uses a stable typed error for corrupt durable state', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-corrupt-'));
    const path = join(directory, 'clipper-snapshot.json');
    await writeFile(path, '{not-json', { mode: 0o600 });
    const store = new ClipperStore(path);
    await expect(store.get()).rejects.toBeInstanceOf(ClipperStoreError);
    await expect(store.get()).rejects.toBeInstanceOf(ClipperStoreError);
  });

  it('rejects a durable envelope with duplicate keys instead of accepting last-key-wins state', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-duplicate-envelope-'));
    const path = join(directory, 'clipper-snapshot.json');
    const envelope = JSON.stringify({ schemaVersion: 1, snapshot, idempotency: [] }).replace(
      '"schemaVersion":1',
      '"schemaVersion":2,"schemaVersion":1',
    );
    await writeFile(path, envelope, { mode: 0o600 });

    await expect(new ClipperStore(path).get())
      .rejects.toMatchObject({ code: 'storage_unavailable' });
  });

  it('rejects a non-private durable store before parsing its contents', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-mode-'));
    const path = join(directory, 'clipper-snapshot.json');
    await writeFile(path, JSON.stringify({ schemaVersion: 1, snapshot, idempotency: [] }), { mode: 0o600 });
    if (process.platform !== 'win32') {
      await chmod(path, 0o644);
      await expect(new ClipperStore(path).get()).rejects.toBeInstanceOf(ClipperStoreError);
    }
  });
});
