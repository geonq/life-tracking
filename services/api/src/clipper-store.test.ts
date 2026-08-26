import { describe, expect, it } from 'vitest';
import { chmod, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ClipperStore, ClipperStoreError } from './clipper-store.js';

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

describe('ClipperStore', () => {
  it('returns an honest unavailable state before the first Hermes observation', async () => {
    const result = await new ClipperStore().get();
    expect(result.availability).toBe('unavailable');
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

  it('persists the latest snapshot and the idempotency journal across reload', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-store-'));
    const path = join(directory, 'clipper-snapshot.json');
    const body = JSON.stringify(snapshot);
    const first = new ClipperStore(path);
    await first.ingest('persistent-key', body);

    const persisted = JSON.parse(await readFile(path, 'utf8'));
    expect(persisted.schemaVersion).toBe(1);
    expect(persisted.snapshot).toEqual(snapshot);

    const reloaded = new ClipperStore(path);
    expect(await reloaded.get()).toEqual(snapshot);
    await expect(reloaded.ingest('persistent-key', body)).resolves.toMatchObject({ kind: 'replay' });
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
