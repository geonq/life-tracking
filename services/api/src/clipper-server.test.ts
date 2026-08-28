import { describe, expect, it } from 'vitest';
import { Readable } from 'node:stream';
import { chmod, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { app } from './server.js';
import { ClipperStore } from './clipper-store.js';

type MockResponse = { statusCode: number; headers: Record<string, string>; body: string; setHeader: (name: string, value: string | number) => void; end: (value?: string | Buffer) => void };
function response(): MockResponse {
  const result = { statusCode: 200, headers: {}, body: '' } as MockResponse;
  result.setHeader = (name, value) => { result.headers[name.toLowerCase()] = String(value); };
  result.end = value => { result.body = value === undefined ? '' : Buffer.isBuffer(value) ? value.toString('utf8') : value; };
  return result;
}

async function call(store: ClipperStore, payload: string | undefined, headers: Record<string, string> = {}, method = 'POST') {
  const request = Readable.from(payload === undefined ? [] : [Buffer.from(payload)]) as Readable & {
    method: string; url: string; headers: Record<string, string>; socket: { remoteAddress: string };
  };
  request.method = method;
  request.url = '/api/clipper/ingest';
  request.headers = headers;
  request.socket = { remoteAddress: '127.0.0.1' };
  const result = response();
  await app(request, result as never, undefined, undefined, undefined, store);
  return { ...result, json: result.body ? JSON.parse(result.body) : undefined };
}

const observedAt = new Date(Date.now() - 30_000).toISOString();
const snapshot = {
  schemaVersion: 1, availability: 'observed' as const, generatedAt: observedAt, currency: 'EUR' as const,
  metrics: {
    views: { availability: 'observed' as const, value: 5, provenance: { source: 'hermes', observedAt, freshness: 'fresh' as const, quality: 'observed' as const, connectorState: 'healthy' as const } },
    subscribers: { availability: 'unavailable' as const, provenance: { source: 'hermes', observedAt, freshness: 'unknown' as const, quality: 'unavailable' as const, connectorState: 'unavailable' as const } },
    revenue: { availability: 'unavailable' as const, currency: 'EUR' as const, provenance: { source: 'hermes', observedAt, freshness: 'unknown' as const, quality: 'unavailable' as const, connectorState: 'unavailable' as const } },
  }, accounts: [], trends: [], breakdowns: [],
  provenance: { source: 'hermes', observedAt, freshness: 'fresh' as const, quality: 'partial' as const, connectorState: 'healthy' as const },
};

describe('Clipper ingest HTTP boundary', () => {
  it('requires enablement and accepts an authenticated idempotent Hermes post', async () => {
    const previousEnabled = process.env.CLIPPER_INGEST_ENABLED;
    const previousSecretFile = process.env.CLIPPER_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-clipper-http-'));
    const secretPath = join(directory, 'clipper.secret');
    const secret = 'c'.repeat(32);
    await writeFile(secretPath, secret, { mode: 0o600 });
    if (process.platform !== 'win32') await chmod(secretPath, 0o600);
    const body = JSON.stringify(snapshot);
    const store = new ClipperStore();
    try {
      delete process.env.CLIPPER_INGEST_ENABLED;
      process.env.CLIPPER_INGEST_SECRET_FILE = secretPath;
      expect((await call(store, body, { authorization: `Bearer ${secret}`, 'content-type': 'application/json', 'idempotency-key': 'one' })).statusCode).toBe(404);

      process.env.CLIPPER_INGEST_ENABLED = 'true';
      const headers = { authorization: `Bearer ${secret}`, 'content-type': 'application/json', 'idempotency-key': 'one' };
      const accepted = await call(store, body, headers);
      expect(accepted.statusCode).toBe(200);
      expect(accepted.json.availability).toBe('observed');
      expect(accepted.headers['x-lifeos-idempotent-replay']).toBeUndefined();

      const replay = await call(store, body, headers);
      expect(replay.statusCode).toBe(200);
      expect(replay.headers['x-lifeos-idempotent-replay']).toBe('true');

      const reuse = await call(store, JSON.stringify({ ...snapshot, metrics: { ...snapshot.metrics, views: { ...snapshot.metrics.views, value: 6 } } }), headers);
      expect(reuse.statusCode).toBe(409);
      expect(reuse.json).toEqual({ error: 'idempotency_key_reuse' });

      const ambiguous = body.replace(
        '"source":"hermes"',
        '"source":"untrusted","sour\\u0063e":"hermes"',
      );
      const duplicate = await call(store, ambiguous, { ...headers, 'idempotency-key': 'duplicate-json-key' });
      expect(duplicate.statusCode).toBe(400);
      expect(duplicate.json).toEqual({ error: 'invalid_json' });
      expect(await store.get()).toEqual(snapshot);

      const olderAt = new Date(Date.now() - 60_000).toISOString();
      const older = {
        ...snapshot,
        generatedAt: olderAt,
        metrics: {
          views: { ...snapshot.metrics.views, provenance: { ...snapshot.metrics.views.provenance, observedAt: olderAt } },
          subscribers: { ...snapshot.metrics.subscribers, provenance: { ...snapshot.metrics.subscribers.provenance, observedAt: olderAt } },
          revenue: { ...snapshot.metrics.revenue, provenance: { ...snapshot.metrics.revenue.provenance, observedAt: olderAt } },
        },
        provenance: { ...snapshot.provenance, observedAt: olderAt },
      };
      const stale = await call(store, JSON.stringify(older), { ...headers, 'idempotency-key': 'older' });
      expect(stale.statusCode).toBe(200);
      expect(stale.headers['x-lifeos-stale-ingest']).toBe('true');
      expect(stale.json).toEqual(snapshot);
    } finally {
      if (previousEnabled === undefined) delete process.env.CLIPPER_INGEST_ENABLED; else process.env.CLIPPER_INGEST_ENABLED = previousEnabled;
      if (previousSecretFile === undefined) delete process.env.CLIPPER_INGEST_SECRET_FILE; else process.env.CLIPPER_INGEST_SECRET_FILE = previousSecretFile;
    }
  });
});
