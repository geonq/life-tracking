import { describe, expect, it } from 'vitest';
import { Readable } from 'node:stream';
import { app } from './server.js';
import { CalendarStore } from './calendar-store.js';

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

async function call(path: string, method = 'GET', remoteAddress = '127.0.0.1'): Promise<Response> {
  const req = Readable.from([]) as Readable & {
    method: string;
    url: string;
    headers: Record<string, string>;
    socket: { remoteAddress: string };
  };
  req.method = method;
  req.url = path;
  req.headers = {};
  req.socket = { remoteAddress: remoteAddress };
  const response = new MockResponse();
  await app(req, response as never);
  return { status: response.statusCode, body: response.body, headers: response.headers };
}

describe('Node API Calendar authority boundary', () => {
  it('hard-disables both legacy Node Calendar routes instead of exposing an in-memory authority', async () => {
    for (const path of ['/api/calendar', '/calendar']) {
      const result = await call(path);
      expect(result.status).toBe(503);
      expect(JSON.parse(result.body)).toEqual({
        error: 'calendar_authority_gateway_only',
        authority: 'gateway',
      });
      expect(result.headers.etag).toBeUndefined();
      expect(result.headers['x-lifeos-revision']).toBeUndefined();
    }
  });

  it('does not turn a non-loopback request into a Calendar authority probe', async () => {
    const result = await call('/api/calendar', 'GET', '203.0.113.9');
    expect(result.status).toBe(403);
    expect(JSON.parse(result.body)).toEqual({ error: 'loopback_only' });
  });

  it('does not expose mutable document state through the test authority fixture', () => {
    const store = new CalendarStore();
    const exposed = store.get();
    exposed.document.items.push({ id: 'caller-mutation' });
    expect(store.get().document.items).toEqual([]);
  });
});
