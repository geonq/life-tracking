import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { EventEmitter } from 'node:events';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { API_MAX_IN_FLIGHT_REQUESTS, createApiServer, startApiServer, type ApiRuntime } from './server.js';

function fakeRuntime() {
  const runtime = new EventEmitter() as EventEmitter & ApiRuntime & { stdin: EventEmitter; exitCode?: string | number | null };
  runtime.stdin = new EventEmitter();
  return runtime;
}

const connectionIsRefused = (port: number) => new Promise<boolean>(resolve => {
  const req = request({ host: '127.0.0.1', port, path: '/health', method: 'GET' }, () => resolve(false));
  req.once('error', () => resolve(true));
  req.end();
});

const responseStatus = (port: number, path: string, headers?: Record<string, string>) => new Promise<number>((resolve, reject) => {
  const req = request({ host: '127.0.0.1', port, path, method: 'GET', headers }, response => {
    response.resume();
    response.once('end', () => resolve(response.statusCode ?? 0));
  });
  req.once('error', reject);
  req.end();
});

const openLongLivedRequest = (port: number, path: string, headers?: Record<string, string>) => {
  let resolveClosed!: () => void;
  const closed = new Promise<void>(resolve => { resolveClosed = resolve; });
  const req = request({ host: '127.0.0.1', port, path, method: 'GET', headers }, response => {
    response.resume();
  });
  req.once('close', resolveClosed);
  req.once('error', () => undefined);
  req.end();
  return { req, closed };
};

describe('API startup lifecycle', () => {
  it('drains and closes the loopback listener on redirected stdin EOF without exiting Vitest', async () => {
    const previousStore = process.env.USAGE_STORE_PATH;
    const previousClipper = process.env.CLIPPER_STORE_PATH;
    const directory = await mkdtemp(join(tmpdir(), 'usage-startup-'));
    const runtime = fakeRuntime();
    process.env.USAGE_STORE_PATH = join(directory, 'history.jsonl');
    process.env.CLIPPER_STORE_PATH = join(directory, 'clipper.json');
    try {
      const started = await startApiServer({ port: 0, runtime });
      const address = started.server.address();
      if (!address || typeof address === 'string') throw new Error('no address');
      runtime.stdin.emit('end');
      await started.closed;
      expect(runtime.exitCode).toBe(0);
      expect(started.server.address()).toBeNull();
      expect(await connectionIsRefused(address.port)).toBe(true);
    } finally {
      if (previousStore === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previousStore;
      if (previousClipper === undefined) delete process.env.CLIPPER_STORE_PATH; else process.env.CLIPPER_STORE_PATH = previousClipper;
    }
  });

  it('fails before binding when readiness configuration is invalid', async () => {
    const previousStore = process.env.USAGE_STORE_PATH;
    process.env.USAGE_STORE_PATH = 'relative-history.jsonl';
    try {
      await expect(startApiServer({ port: 0, runtime: fakeRuntime() })).rejects.toThrow('startup_configuration_invalid');
    } finally {
      if (previousStore === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previousStore;
    }
  });

  it('holds admission slots until handlers settle after clients disconnect', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'api-admission-'));
    const secret = 'api-admission-test-credential-'.repeat(2);
    const secretFile = join(directory, 'local-api-secret');
    await writeFile(secretFile, secret, { mode: 0o600 });
    const previousEnabled = process.env.LIFEOS_LOCAL_API_ENABLED;
    const previousSecretFile = process.env.LIFEOS_LOCAL_API_SECRET_FILE;
    process.env.LIFEOS_LOCAL_API_ENABLED = 'true';
    process.env.LIFEOS_LOCAL_API_SECRET_FILE = secretFile;
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    let started = 0;
    let releaseStarted!: () => void;
    const allStarted = new Promise<void>(resolve => { releaseStarted = resolve; });
    const server = createApiServer(async () => {
      started += 1;
      if (started === API_MAX_IN_FLIGHT_REQUESTS) releaseStarted();
      await held;
      return { connectorState: 'unavailable' as const, windows: [] };
    });
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    try {
      const address = server.address();
      if (!address || typeof address === 'string') throw new Error('no address');
      const pending = Array.from({ length: API_MAX_IN_FLIGHT_REQUESTS }, () => openLongLivedRequest(
        address.port,
        '/api/codex/live',
        { Authorization: `Bearer ${secret}` },
      ));
      await allStarted;

      // Destroy the client side of every exchange while the injected handler
      // is still held. The server's response close events must not return the
      // slots because app() is still pending.
      for (const client of pending) client.req.destroy();
      await Promise.all(pending.map(client => client.closed));
      await expect(responseStatus(address.port, '/api/codex/live', { Authorization: `Bearer ${secret}` })).resolves.toBe(503);

      release();
      await expect(responseStatus(address.port, '/api/codex/live', { Authorization: `Bearer ${secret}` })).resolves.toBe(200);
    } finally {
      release();
      if (server.listening) await new Promise<void>(resolve => server.close(() => resolve()));
      if (previousEnabled === undefined) delete process.env.LIFEOS_LOCAL_API_ENABLED; else process.env.LIFEOS_LOCAL_API_ENABLED = previousEnabled;
      if (previousSecretFile === undefined) delete process.env.LIFEOS_LOCAL_API_SECRET_FILE; else process.env.LIFEOS_LOCAL_API_SECRET_FILE = previousSecretFile;
      await rm(directory, { recursive: true, force: true });
    }
  }, 15_000);
});
