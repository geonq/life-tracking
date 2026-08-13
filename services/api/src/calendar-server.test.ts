import { describe, expect, it } from 'vitest';
import { Readable } from 'node:stream';
import { CalendarStore } from './calendar-store.js';
import { app } from './server.js';

type Response = { status: number; body: string; headers: Record<string, string | string[] | undefined> };

class MockResponse {
  statusCode = 200;
  readonly headers: Record<string, string | string[] | undefined> = {};
  body = '';

  setHeader(name: string, value: string | number) {
    this.headers[name.toLowerCase()] = String(value);
    return this;
  }

  end(value?: string | Buffer) {
    this.body = value === undefined ? '' : Buffer.isBuffer(value) ? value.toString('utf8') : value;
    return this;
  }
}

async function call(store: CalendarStore, path: string, method = 'GET', payload?: string, headers: Record<string, string> = {}): Promise<Response> {
  const req = Readable.from(payload === undefined ? [] : [Buffer.from(payload)]) as Readable & {
    method: string;
    url: string;
    headers: Record<string, string>;
    socket: { remoteAddress: string };
  };
  req.method = method;
  req.url = path;
  req.headers = headers;
  req.socket = { remoteAddress: '127.0.0.1' };
  const response = new MockResponse();
  await app(req, response as never, undefined, undefined, store);
  return { status: response.statusCode, body: response.body, headers: response.headers };
}

async function withServer<T>(run: (store: CalendarStore) => Promise<T>): Promise<T> {
  return run(new CalendarStore());
}

function etag(response: Response): string {
  const value = response.headers.etag;
  if (typeof value !== 'string') throw new Error('missing ETag');
  return value;
}

describe('local conditional Calendar server foundation', () => {
  it('returns canonical JSON and a deterministic strong quoted ETag', async () => {
    await withServer(async store => {
      const first = await call(store, '/api/calendar');
      const second = await call(store, '/calendar');

      expect(first.status).toBe(200);
      expect(first.body).toBe('{"schemaVersion":1,"items":[]}');
      expect(second.body).toBe(first.body);
      expect(etag(first)).toBe(etag(second));
      expect(etag(first)).toMatch(/^"calendar-v1-r0-[0-9a-f]{64}"$/);
      expect(Buffer.byteLength(first.body)).toBeLessThanOrEqual(256 * 1024);
    });
  });

  it('requires valid If-Match and Idempotency-Key and returns authoritative truth on failure', async () => {
    await withServer(async store => {
      const initial = await call(store, '/api/calendar');
      const body = JSON.stringify({ schemaVersion: 1, items: [] });
      const cases = [
        { headers: { 'content-type': 'application/json', 'idempotency-key': 'missing-if-match' }, status: 428 },
        { headers: { 'content-type': 'application/json', 'if-match': 'W/"calendar-v1-r0-invalid"', 'idempotency-key': 'weak-etag' }, status: 400 },
        { headers: { 'content-type': 'application/json', 'if-match': etag(initial) }, status: 400 },
        { headers: { 'content-type': 'application/json', 'if-match': etag(initial), 'idempotency-key': ' ' }, status: 400 },
      ];

      for (const candidate of cases) {
        const result = await call(store, '/api/calendar', 'PUT', body, candidate.headers);
        expect(result.status).toBe(candidate.status);
        expect(result.body).toBe(initial.body);
        expect(etag(result)).toBe(etag(initial));
      }
      const unchanged = await call(store, '/api/calendar');
      expect(unchanged.body).toBe(initial.body);
      expect(etag(unchanged)).toBe(etag(initial));
    });
  });

  it('rejects a stale revision without mutation and returns the current snapshot plus ETag', async () => {
    await withServer(async store => {
      const initial = await call(store, '/api/calendar');
      const firstBody = JSON.stringify({ schemaVersion: 1, items: [{ id: 'one' }] });
      const first = await call(store, '/api/calendar', 'PUT', firstBody, {
        'content-type': 'application/json', 'if-match': etag(initial), 'idempotency-key': 'first-write',
      });
      expect(first.status).toBe(200);

      const staleBody = JSON.stringify({ schemaVersion: 1, items: [{ id: 'stale' }] });
      const conflict = await call(store, '/api/calendar', 'PUT', staleBody, {
        'content-type': 'application/json', 'if-match': etag(initial), 'idempotency-key': 'stale-write',
      });
      expect(conflict.status).toBe(412);
      expect(conflict.body).toBe(first.body);
      expect(etag(conflict)).toBe(etag(first));

      const current = await call(store, '/api/calendar');
      expect(current.body).toBe(first.body);
      expect(etag(current)).toBe(etag(first));
    });
  });

  it('replays an accepted idempotency key ten times with exactly one logical mutation', async () => {
    await withServer(async store => {
      const initial = await call(store, '/api/calendar');
      const body = JSON.stringify({ schemaVersion: 1, items: [{ id: 'one' }] });
      const headers = {
        'content-type': 'application/json', 'if-match': etag(initial), 'idempotency-key': 'replay-me',
      };
      const accepted = await call(store, '/api/calendar', 'PUT', body, headers);
      expect(accepted.status).toBe(200);
      expect(accepted.headers['x-lifeos-idempotent-replay']).toBeUndefined();

      for (let index = 0; index < 10; index += 1) {
        const replay = await call(store, '/api/calendar', 'PUT', body, headers);
        expect(replay.status).toBe(200);
        expect(replay.body).toBe(accepted.body);
        expect(etag(replay)).toBe(etag(accepted));
        expect(replay.headers['x-lifeos-idempotent-replay']).toBe('true');
      }

      const current = await call(store, '/api/calendar');
      expect(current.body).toBe(accepted.body);
      expect(etag(current)).toBe(etag(accepted));
    });
  });

  it('replays an accepted key after a later revision as current authoritative truth', async () => {
    await withServer(async store => {
      const initial = await call(store, '/api/calendar');
      const firstBody = JSON.stringify({ schemaVersion: 1, items: [{ id: 'first' }] });
      const firstHeaders = {
        'content-type': 'application/json', 'if-match': etag(initial), 'idempotency-key': 'first-key',
      };
      const first = await call(store, '/api/calendar', 'PUT', firstBody, firstHeaders);
      expect(first.status).toBe(200);

      const laterBody = JSON.stringify({ schemaVersion: 1, items: [{ id: 'later' }] });
      const later = await call(store, '/api/calendar', 'PUT', laterBody, {
        'content-type': 'application/json', 'if-match': etag(first), 'idempotency-key': 'later-key',
      });
      expect(later.status).toBe(200);

      const replay = await call(store, '/api/calendar', 'PUT', firstBody, firstHeaders);
      expect(replay.status).toBe(200);
      expect(replay.headers['x-lifeos-idempotent-replay']).toBe('true');
      expect(replay.body).toBe(later.body);
      expect(etag(replay)).toBe(etag(later));

      const current = await call(store, '/api/calendar');
      expect(current.body).toBe(later.body);
      expect(etag(current)).toBe(etag(later));
    });
  });

  it('keeps envelope-only item validation explicit for this local dumb-blob fixture', async () => {
    await withServer(async store => {
      const initial = await call(store, '/api/calendar');
      const body = JSON.stringify({ schemaVersion: 1, items: [{ notAValidatedCalendarItem: true }] });
      const accepted = await call(store, '/api/calendar', 'PUT', body, {
        'content-type': 'application/json', 'if-match': etag(initial), 'idempotency-key': 'envelope-only',
      });
      expect(accepted.status).toBe(200);
      expect(accepted.body).toBe(body);
      // This acceptance is deliberately limited to the local dumb-blob
      // protocol fixture; production CalendarItem validation remains unaccepted.
    });
  });

  it('rejects idempotency-key reuse with different bytes and bounds malformed/oversized bodies', async () => {
    await withServer(async store => {
      const initial = await call(store, '/api/calendar');
      const body = JSON.stringify({ schemaVersion: 1, items: [{ id: 'one' }] });
      const headers = {
        'content-type': 'application/json', 'if-match': etag(initial), 'idempotency-key': 'reuse-me',
      };
      const accepted = await call(store, '/api/calendar', 'PUT', body, headers);
      const reuse = await call(store, '/api/calendar', 'PUT', JSON.stringify({ schemaVersion: 1, items: [{ id: 'two' }] }), headers);
      expect(reuse.status).toBe(409);
      expect(reuse.body).toBe(accepted.body);
      expect(etag(reuse)).toBe(etag(accepted));

      const malformed = await call(store, '/api/calendar', 'PUT', '{not-json', {
        'content-type': 'application/json', 'if-match': etag(accepted), 'idempotency-key': 'malformed',
      });
      expect(malformed.status).toBe(400);

      const oversized = await call(store, '/api/calendar', 'PUT', 'x'.repeat(256 * 1024 + 1), {
        'content-type': 'application/json', 'if-match': etag(accepted), 'idempotency-key': 'oversized',
      });
      expect(oversized.status).toBe(413);
      const current = await call(store, '/api/calendar');
      expect(current.body).toBe(accepted.body);
      expect(etag(current)).toBe(etag(accepted));
    });
  });
});
