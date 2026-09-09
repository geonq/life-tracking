import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { request } from 'node:http';
import { Readable } from 'node:stream';
import { chmod, mkdtemp, mkdir, readFile, rm, rmdir, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { app, createApiServer, startApiServer, validateStartupConfiguration } from './server.js';

import { authorizeLocalApi } from './local-auth.js';

const LOCAL_SECRET = 'local-service-test-credential-'.repeat(2);
const localHeaders = () => ({ authorization: `Bearer ${LOCAL_SECRET}` });

// Maintained independently from local-auth.ts so this test still detects a
// route that loses protection when the production route list changes.
const SENSITIVE_LOCAL_ROUTES: ReadonlyArray<readonly [string, string]> = [
  ['GET', '/api/usage'],
  ['GET', '/api/codex/live'],
  ['GET', '/api/clipper/summary'],
  ['POST', '/api/nutrition/photo-proposal'],
  ['POST', '/nutrition/photo-proposal'],
];
let localDirectory: string;
beforeEach(async () => {
  localDirectory = await mkdtemp(join(tmpdir(), 'lifeos-local-auth-'));
  const path = join(localDirectory, 'secret');
  await writeFile(path, LOCAL_SECRET, { mode: 0o600 });
  vi.stubEnv('LIFEOS_LOCAL_API_ENABLED', 'true');
  vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', path);
});
afterEach(async () => {
  vi.unstubAllEnvs();
  await rm(localDirectory, { recursive: true, force: true });
});

const LOOPBACK_HOST = '127.0.0.1';

const postClaudeIngest = (port: number, secret: string) => new Promise<{ status: number; body: string }>(resolve => {
  const req = request({ host: LOOPBACK_HOST, port, path: '/api/usage/claude-ingest', method: 'POST', headers: {
    authorization: `Bearer ${secret}`, 'content-type': 'application/json', 'idempotency-key': 'claude-empty-test',
  } }, response => { let value = ''; response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: value })); });
  req.end('{}');
});
const postClaudePayload = (port: number, secret: string, payload: unknown, extraHeaders: Record<string, string> = {}) => new Promise<{ status: number; body: string }>(resolve => {
  const req = request({ host: LOOPBACK_HOST, port, path: '/api/usage/claude-ingest', method: 'POST', headers: {
    authorization: `Bearer ${secret}`, 'content-type': 'application/json', 'idempotency-key': 'claude-test-capture', ...extraHeaders,
  } }, response => { let value = ''; response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: value })); });
  req.end(JSON.stringify(payload));
});
const postCodexPayload = (port: number, secret: string, payload: unknown) => new Promise<{ status: number; body: string }>(resolve => {
  const req = request({ host: LOOPBACK_HOST, port, path: '/api/usage/codex-ingest', method: 'POST', headers: {
    authorization: `Bearer ${secret}`, 'content-type': 'application/json', 'idempotency-key': 'codex-test-capture',
  } }, response => { let value = ''; response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: value })); });
  req.end(JSON.stringify(payload));
});
const getUsage = (port: number) => new Promise<{ status: number; body: any }>(resolve => {
  const req = request({ host: LOOPBACK_HOST, port, path: '/api/usage', headers: localHeaders(), method: 'GET' }, response => { let value = ''; response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: JSON.parse(value) })); });
  req.end();
});
const listenApiServer = (server: ReturnType<typeof createApiServer>) => new Promise<void>((resolve, reject) => {
  const onError = (error: Error) => { server.removeListener('error', onError); reject(error); };
  server.once('error', onError);
  server.listen(0, LOOPBACK_HOST, () => { server.removeListener('error', onError); resolve(); });
});
const closeApiServer = (server: ReturnType<typeof createApiServer>) => new Promise<void>(resolve => {
  if (!server.listening) { resolve(); return; }
  server.close(() => resolve());
});

describe('HTTP API', () => {
  it('rejects malformed and mismatched Content-Length before parsing JSON', async () => {
    const callWithLength = async (contentLength: string) => {
      const req = Readable.from([Buffer.from('{}')]) as Readable & {
        method: string;
        url: string;
        headers: Record<string, string>;
        socket: { remoteAddress: string };
      };
      req.method = 'POST';
      req.url = '/api/nutrition/photo-proposal';
      req.headers = { ...localHeaders(), 'content-type': 'application/json', 'content-length': contentLength };
      req.socket = { remoteAddress: LOOPBACK_HOST };
      let body = '';
      const response = {
        statusCode: 200,
        setHeader: () => undefined,
        end: (value?: string | Buffer) => { body = value === undefined ? '' : Buffer.isBuffer(value) ? value.toString('utf8') : value; },
      };
      await app(req, response as never, undefined, undefined, undefined, { generate: async () => { throw new Error('must not parse'); } });
      return { status: response.statusCode, body };
    };

    expect(await callWithLength('1')).toEqual({ status: 400, body: '{"error":"invalid_request"}' });
    expect(await callWithLength('2e0')).toEqual({ status: 400, body: '{"error":"invalid_request"}' });
  });

  it('preserves direct Codex capture time through the usage response', async () => {
    const previousEnabled = process.env.CODEX_LIVE_ENABLED;
    const previousStore = process.env.USAGE_STORE_PATH;
    const directory = await mkdtemp(join(tmpdir(), 'usage-codex-capture-'));
    const captured = new Date(Date.now() - 16 * 60 * 1000).toISOString();
    process.env.CODEX_LIVE_ENABLED = 'true';
    process.env.USAGE_STORE_PATH = join(directory, 'history.jsonl');
    const server = createApiServer(async () => ({
      connectorState: 'healthy',
      observedAt: captured,
      windows: [{ minutes: 300, usedPercent: 12 }],
    }));
    await listenApiServer(server);
    const address = server.address();
    if (!address || typeof address === 'string') throw Error('no address');
    const result = await new Promise<{ status: number; body: any }>(resolve => {
      const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/usage', headers: localHeaders(), method: 'GET' }, response => {
        let value = '';
        response.on('data', chunk => value += chunk);
        response.on('end', () => resolve({ status: response.statusCode!, body: JSON.parse(value) }));
      });
      req.end();
    });
    await new Promise(resolve => server.close(resolve));
    if (previousEnabled === undefined) delete process.env.CODEX_LIVE_ENABLED; else process.env.CODEX_LIVE_ENABLED = previousEnabled;
    if (previousStore === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previousStore;

    expect(result.status).toBe(200);
    expect(result.body.windows[0]).toMatchObject({
      provider: 'codex',
      availability: 'observed',
      usedPercent: 12,
      provenance: { observedAt: captured, freshness: 'stale', connectorState: 'refresh_due' },
    });
    expect(result.body.connectors.codex).toBe('refresh_due');
  });

  it('ignores inline Claude secrets when no secret file is configured', async () => {
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecret = process.env.CLAUDE_INGEST_SECRET;
    const previousStatuslineToken = process.env.CLAUDE_STATUSLINE_TOKEN;
    const previousSecretFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET = 'a'.repeat(32);
    process.env.CLAUDE_STATUSLINE_TOKEN = 'b'.repeat(32);
    delete process.env.CLAUDE_INGEST_SECRET_FILE;
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const result = await new Promise<{ status: number; body: { error?: string } }>(resolve => {
      const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/usage/claude-ingest', method: 'POST', headers: {
        authorization: `Bearer ${'a'.repeat(32)}`, 'content-type': 'application/json',
      } }, response => { let value = ''; response.on('data', chunk => value += chunk);
        response.on('end', () => resolve({ status: response.statusCode!, body: JSON.parse(value) })); });
      req.end('{}');
    });
    await new Promise(resolve => server.close(resolve));
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    if (previousSecret === undefined) delete process.env.CLAUDE_INGEST_SECRET; else process.env.CLAUDE_INGEST_SECRET = previousSecret;
    if (previousSecretFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousSecretFile;
    expect(result).toEqual({ status: 401, body: { error: 'unauthorized' } });
    if (previousStatuslineToken === undefined) delete process.env.CLAUDE_STATUSLINE_TOKEN; else process.env.CLAUDE_STATUSLINE_TOKEN = previousStatuslineToken;
  });
  it('prefers a validated Claude secret file and never falls back when it is bad', async () => {
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecret = process.env.CLAUDE_INGEST_SECRET;
    const previousFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-claude-secret-'));
    const secretPath = join(directory, 'claude-ingest.secret');
    const fileSecret = 'f'.repeat(32);
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET = 'i'.repeat(32);
    process.env.CLAUDE_INGEST_SECRET_FILE = secretPath;
    await writeFile(secretPath, fileSecret, { mode: 0o600 });
    await chmod(secretPath, 0o600);
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const accepted = await postClaudeIngest(address.port, fileSecret);
    const inlineRejected = await postClaudeIngest(address.port, 'i'.repeat(32));
    await new Promise(resolve => server.close(resolve));
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    if (previousSecret === undefined) delete process.env.CLAUDE_INGEST_SECRET; else process.env.CLAUDE_INGEST_SECRET = previousSecret;
    if (previousFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousFile;
    expect(accepted.status).toBe(422);
    expect(inlineRejected).toEqual({ status: 401, body: '{"error":"unauthorized"}' });
  });
  it('fails closed for missing, short, whitespace, and oversized Claude secret files', async () => {
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecret = process.env.CLAUDE_INGEST_SECRET;
    const previousFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-claude-bad-secret-'));
    const secretPath = join(directory, 'claude-ingest.secret');
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET = 'i'.repeat(32);
    process.env.CLAUDE_INGEST_SECRET_FILE = secretPath;
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    for (const value of [undefined, 'short', 'v'.repeat(31), `${'v'.repeat(32)}\n`, 'x'.repeat(4097)]) {
      if (value === undefined) {
        await expect(postClaudeIngest(address.port, 'i'.repeat(32))).resolves.toMatchObject({ status: 401 });
      } else {
        await writeFile(secretPath, value);
        await expect(postClaudeIngest(address.port, value.trim())).resolves.toMatchObject({ status: 401 });
      }
    }
    await new Promise(resolve => server.close(resolve));
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    if (previousSecret === undefined) delete process.env.CLAUDE_INGEST_SECRET; else process.env.CLAUDE_INGEST_SECRET = previousSecret;
    if (previousFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousFile;
  });
  it('fails closed for secret symlinks, directories, and permissive modes', async () => {
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecretFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-claude-file-types-'));
    const secretPath = join(directory, 'claude-ingest.secret');
    const targetPath = join(directory, 'target.secret');
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET_FILE = secretPath;
    await writeFile(targetPath, 't'.repeat(32), { mode: 0o600 });
    await chmod(targetPath, 0o600);
    await writeFile(secretPath, 's'.repeat(32), { mode: 0o600 });
    await chmod(secretPath, 0o600);
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');

    if (process.platform !== 'win32') {
      await chmod(secretPath, 0o644);
      expect((await postClaudeIngest(address.port, 's'.repeat(32))).status).toBe(401);
    }
    await unlink(secretPath);
    await mkdir(secretPath);
    expect((await postClaudeIngest(address.port, 's'.repeat(32))).status).toBe(401);
    await rmdir(secretPath);
    if (process.platform !== 'win32') {
      await symlink(targetPath, secretPath);
      expect((await postClaudeIngest(address.port, 't'.repeat(32))).status).toBe(401);
      await unlink(secretPath);
    }

    await new Promise(resolve => server.close(resolve));
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    if (previousSecretFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousSecretFile;
  });
  it('serves health, overview and codex, rejects methods and unknown paths', async () => {
    const previousApiMode = process.env.LIFEOS_API_MODE;
    let server: ReturnType<typeof createApiServer> | undefined;
    try {
      process.env.LIFEOS_API_MODE = 'test';
      server = createApiServer(); await listenApiServer(server);
      const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
      const call = (path:string, method='GET') => new Promise<{status:number; body:any}>(resolve => { const req=request({host:LOOPBACK_HOST,port:address.port,path,method,headers:localHeaders()}, res=>{let b='';res.on('data',x=>b+=x);res.on('end',()=>resolve({status:res.statusCode!,body:JSON.parse(b)}))});req.end(); });
      const health = await call('/health');
      expect(health.body).toMatchObject({ status: 'ok', mode: 'test', readiness: 'ready' });
      expect(health.body).not.toHaveProperty('demo');
      expect((await call('/api/overview')).body.label).toBe('Demo data');
      expect((await call('/api/codex')).body.kind).toBe('codex');

      const usage = await call('/api/usage');
      expect(usage.status).toBe(200);
      expect(Object.keys(usage.body.connectors)).toEqual([
        'codex', 'claude', 'glm', 'deepseek', 'google_ai_studio',
      ]);
      expect(usage.body.connectors.glm).toBe('unavailable');
      expect(usage.body.connectors.deepseek).toBe('unavailable');
      expect(usage.body.connectors.google_ai_studio).toBe('unavailable');

      const finance = await call('/api/finance/connectors');
      expect(finance.status).toBe(200);
      expect(finance.body.connectors.map((connector: { id: string }) => connector.id)).toEqual([
        'sparkasse_leipzig',
        'revolut_personal',
        'revolut_business',
        'trade_republic',
      ]);
      expect(finance.body.connectors.every((connector: { enabled: boolean }) => !connector.enabled)).toBe(true);
      expect(finance.body.connectors.every((connector: { requiresExplicitOptIn: boolean }) => connector.requiresExplicitOptIn)).toBe(true);
      expect(finance.body.connectors.filter((connector: { provider: string }) => connector.provider === 'Enable Banking')).toHaveLength(2);
      expect(finance.body.connectors.filter((connector: { risk: string }) => connector.risk === 'consent_required')).toHaveLength(2);
      expect(finance.body.connectors.find((connector: { id: string }) => connector.id === 'revolut_business')).toMatchObject({
        accessMethod: 'official_oauth',
        provider: 'Official Revolut Business API',
        risk: 'account_eligibility_required',
      });
      expect(finance.body.connectors.find((connector: { id: string }) => connector.id === 'trade_republic')).toMatchObject({
        accessMethod: 'manual_import',
        provider: 'Manual CSV/PDF import',
        risk: 'manual_import_only',
      });
      const financeSummary = await call('/api/finance/summary');
      expect(financeSummary.status).toBe(200);
      expect(financeSummary.body.currency).toBe('EUR');
      for (const key of ['monthlyIncome', 'fixedCosts', 'discretionaryBuffer', 'spent', 'savingsGoal', 'saved']) {
        expect(financeSummary.body[key]).toMatchObject({ availability: 'unavailable', provenance: { quality: 'unavailable', connectorState: 'unavailable' } });
        expect(financeSummary.body[key]).not.toHaveProperty('amountCents');
      }
      // A summary-only unavailable response must omit the transaction snapshot;
      // an empty array would falsely claim that a connector observed an empty ledger.
      expect(financeSummary.body).not.toHaveProperty('transactions');

      const clipper = await call('/api/clipper/summary');
      expect(clipper.status).toBe(200);
      expect(clipper.body).toMatchObject({
        schemaVersion: 1,
        availability: 'unavailable',
        currency: 'EUR',
        provenance: {
          source: 'no-authorized-clipper-source',
          quality: 'unavailable',
          freshness: 'unknown',
          connectorState: 'unavailable',
        },
      });
      expect(clipper.body).not.toHaveProperty('metrics');
      expect(clipper.body).not.toHaveProperty('accounts');

      expect((await call('/missing')).status).toBe(404);
      expect((await call('/health','POST')).status).toBe(405);
    } finally {
      if (server) await closeApiServer(server);
      if (previousApiMode === undefined) delete process.env.LIFEOS_API_MODE; else process.env.LIFEOS_API_MODE = previousApiMode;
    }
  });

  it('fails closed for fixture routes in production and arbitrary non-test modes', async () => {
    const previousNodeEnv = process.env.NODE_ENV;
    const previousApiMode = process.env.LIFEOS_API_MODE;
    let server: ReturnType<typeof createApiServer> | undefined;
    try {
      server = createApiServer(); await listenApiServer(server);
      const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
      const call = (path: string) => new Promise<{ status: number; body: any }>(resolve => {
        const req = request({ host: LOOPBACK_HOST, port: address.port, path }, response => {
          let value = ''; response.on('data', chunk => value += chunk);
          response.on('end', () => resolve({ status: response.statusCode!, body: JSON.parse(value) }));
        });
        req.end();
      });
      const modes: Array<{ nodeEnv: string; apiMode?: string }> = [
        { nodeEnv: 'production', apiMode: 'fixture' },
        { nodeEnv: 'production', apiMode: 'test' },
        { nodeEnv: 'production' },
        { nodeEnv: 'development' },
        { nodeEnv: 'staging' },
      ];
      for (const { nodeEnv, apiMode: configuredMode } of modes) {
        process.env.NODE_ENV = nodeEnv;
        if (configuredMode === undefined) delete process.env.LIFEOS_API_MODE; else process.env.LIFEOS_API_MODE = configuredMode;
        const health = await call('/health');
        expect(health.status).toBe(200);
        expect(health.body).toMatchObject({ status: 'ok', mode: nodeEnv === 'production' ? 'production' : 'development', readiness: 'ready' });
        expect(health.body).not.toHaveProperty('demo');

        for (const path of ['/api/overview', '/api/codex']) {
          const result = await call(path);
          expect(result.status).toBe(503);
          expect(result.body).toEqual({
            error: 'unavailable',
            code: 'fixture_route_unavailable',
            reason: 'explicit_fixture_or_test_mode_required',
          });
          expect(JSON.stringify(result.body)).not.toContain('Demo data');
        }
      }

      process.env.NODE_ENV = 'production';
      delete process.env.LIFEOS_API_MODE;
      const finance = await call('/api/finance/summary');
      expect(finance.status).toBe(200);
      expect(finance.body.monthlyIncome).toMatchObject({ availability: 'unavailable' });
      expect(finance.body.monthlyIncome).not.toHaveProperty('amountCents');

      process.env.NODE_ENV = 'development';
      process.env.LIFEOS_API_MODE = 'fixture';
      expect((await call('/api/overview')).status).toBe(200);
      expect((await call('/api/codex')).status).toBe(200);
    } finally {
      if (server) await closeApiServer(server);
      if (previousNodeEnv === undefined) delete process.env.NODE_ENV; else process.env.NODE_ENV = previousNodeEnv;
      if (previousApiMode === undefined) delete process.env.LIFEOS_API_MODE; else process.env.LIFEOS_API_MODE = previousApiMode;
    }
  });

  it('fails closed when Claude ingestion is enabled but no observation exists', async () => {
    const previous = process.env.CLAUDE_INGEST_ENABLED;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const result = await new Promise<{ status: number; body: { connectors: { claude: string }; windows: unknown[] } }>(resolve => {
      const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/usage', headers: localHeaders() }, res => {
        let body = ''; res.on('data', chunk => body += chunk); res.on('end', () => resolve({ status: res.statusCode!, body: JSON.parse(body) }));
      }); req.end();
    });
    await new Promise(r => server.close(r));
    if (previous === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previous;
    expect(result.status).toBe(200);
    expect(result.body.connectors.claude).toBe('unavailable');
    expect(result.body.windows).toEqual([]);
  });

  it('marks cached-only Claude observations refresh due instead of healthy', async () => {
    const previousStore = process.env.USAGE_STORE_PATH;
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const directory = await mkdtemp(join(tmpdir(), 'usage-claude-stale-'));
    const storePath = join(directory, 'history.jsonl');
    process.env.USAGE_STORE_PATH = storePath;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    const staleObservedAt = new Date(Date.now() - 60 * 60_000).toISOString();
    await writeFile(storePath, JSON.stringify({ provider: 'claude', window: 'five_hour',
      durationMinutes: 300, usedPercent: 25, observedAt: staleObservedAt }) + '\n');
    const server = createApiServer(async () => ({ connectorState: 'unavailable', windows: [] }));
    await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const body = await new Promise<{ connectors: { claude: string }; windows: Array<{ provider: string; provenance: { connectorState: string } }> }>(resolve => {
      const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/usage', headers: localHeaders() }, response => {
        let value = ''; response.on('data', chunk => value += chunk); response.on('end', () => resolve(JSON.parse(value)));
      }); req.end();
    });
    await new Promise(resolve => server.close(resolve));
    if (previousStore === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previousStore;
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    expect(body.connectors.claude).toBe('refresh_due');
    expect(body.windows.find(window => window.provider === 'claude')?.provenance.connectorState).toBe('refresh_due');
  });

  it('does not mutate the history store while serving a live usage read', async () => {
    const previous = process.env.USAGE_STORE_PATH;
    const directory = await mkdtemp(join(tmpdir(), 'usage-read-'));
    const storePath = join(directory, 'history.jsonl');
    process.env.USAGE_STORE_PATH = storePath;
    const server = createApiServer(async () => ({ connectorState: 'healthy', windows: [{ minutes: 300, usedPercent: 25 }] }));
    await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    await new Promise<void>(resolve => {
      const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/usage', headers: localHeaders() }, response => { response.resume(); response.on('end', resolve); });
      req.end();
    });
    await new Promise(resolve => server.close(resolve));
    if (previous === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previous;
    await expect(readFile(storePath, 'utf8')).rejects.toMatchObject({ code: 'ENOENT' });
  });

  it('prefers a live Codex window over an older cached copy', async () => {
    const previous = process.env.USAGE_STORE_PATH;
    const previousLive = process.env.CODEX_LIVE_ENABLED;
    const directory = await mkdtemp(join(tmpdir(), 'usage-dedupe-'));
    const storePath = join(directory, 'history.jsonl');
    process.env.USAGE_STORE_PATH = storePath;
    process.env.CODEX_LIVE_ENABLED = 'true';
    await writeFile(storePath, JSON.stringify({
      provider: 'codex', window: 'five_hour', durationMinutes: 300,
      usedPercent: 10, observedAt: '2020-01-01T00:00:00Z',
    }) + '\n');
    const server = createApiServer(async () => ({ connectorState: 'healthy', windows: [{ minutes: 300, usedPercent: 25 }] }));
    await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const body = await new Promise<{ windows: Array<{ provider: string; window: string; usedPercent?: number }> }>(resolve => {
      const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/usage', headers: localHeaders() }, response => {
        let value = ''; response.on('data', chunk => value += chunk); response.on('end', () => resolve(JSON.parse(value)));
      }); req.end();
    });
    await new Promise(resolve => server.close(resolve));
    if (previous === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previous;
    if (previousLive === undefined) delete process.env.CODEX_LIVE_ENABLED; else process.env.CODEX_LIVE_ENABLED = previousLive;
    const matching = body.windows.filter(window => window.provider === 'codex' && window.window === 'five_hour');
    expect(matching).toHaveLength(1);
    expect(matching[0]?.usedPercent).toBe(25);
  });

  it('does not relabel unsupported live Codex durations', async () => {
    const previous = process.env.USAGE_STORE_PATH;
    const directory = await mkdtemp(join(tmpdir(), 'usage-duration-'));
    process.env.USAGE_STORE_PATH = join(directory, 'history.jsonl');
    const server = createApiServer(async () => ({ connectorState: 'healthy', windows: [{ minutes: 60, usedPercent: 25 }] }));
    await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const body = await new Promise<{ windows: unknown[] }>(resolve => {
      const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/usage', headers: localHeaders() }, response => {
        let value = ''; response.on('data', chunk => value += chunk); response.on('end', () => resolve(JSON.parse(value)));
      }); req.end();
    });
    await new Promise(resolve => server.close(resolve));
    if (previous === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previous;
    expect(body.windows).toEqual([]);
  });

  it('writes both validated Claude windows as one history batch', async () => {
    const previousStore = process.env.USAGE_STORE_PATH;
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecret = process.env.CLAUDE_INGEST_SECRET;
    const previousSecretFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-claude-batch-'));
    const storePath = join(directory, 'history.jsonl');
    const secretPath = join(directory, 'secret');
    const secret = 'b'.repeat(32);
    process.env.USAGE_STORE_PATH = storePath;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET = 'wrong'.repeat(8);
    process.env.CLAUDE_INGEST_SECRET_FILE = secretPath;
    await writeFile(secretPath, secret, { mode: 0o600 });
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const result = await postClaudePayload(address.port, secret, { rate_limits: {
      five_hour: { used_percentage: 12, resets_at: '2026-08-10T05:00:00Z' },
      seven_day: { used_percentage: 3, resets_at: '2026-08-17T00:00:00Z' },
    } });
    await new Promise(resolve => server.close(resolve));
    if (previousStore === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previousStore;
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    if (previousSecret === undefined) delete process.env.CLAUDE_INGEST_SECRET; else process.env.CLAUDE_INGEST_SECRET = previousSecret;
    if (previousSecretFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousSecretFile;
    expect(result.status).toBe(200);
    const lines = (await readFile(storePath, 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
    expect(lines).toHaveLength(2);
    expect(lines.map((line: { window: string }) => line.window)).toEqual(['five_hour', 'seven_day']);
  });

  it('uses a validated Claude capture timestamp for the response and history', async () => {
    const previousStore = process.env.USAGE_STORE_PATH;
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecretFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-claude-capture-time-'));
    const storePath = join(directory, 'history.jsonl');
    const secretPath = join(directory, 'secret');
    const secret = 'd'.repeat(32);
    const observedAt = new Date(Date.now() - 60_000).toISOString();
    process.env.USAGE_STORE_PATH = storePath;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET_FILE = secretPath;
    delete process.env.CLAUDE_INGEST_SECRET;
    await writeFile(secretPath, secret, { mode: 0o600 });
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const result = await postClaudePayload(address.port, secret, { rate_limits: {
      five_hour: { used_percentage: 12, resets_at: '2026-08-10T05:00:00Z' },
    } }, { 'x-observed-at': observedAt });
    const future = await postClaudePayload(address.port, secret, { rate_limits: {
      five_hour: { used_percentage: 12, resets_at: '2026-08-10T05:00:00Z' },
    } }, { 'x-observed-at': new Date(Date.now() + 60_000).toISOString() });
    await new Promise(resolve => server.close(resolve));
    if (previousStore === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previousStore;
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    if (previousSecretFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousSecretFile;
    expect(result.status).toBe(200);
    expect(JSON.parse(result.body).windows[0].provenance.observedAt).toBe(observedAt);
    expect(future).toEqual({ status: 400, body: '{"error":"invalid_request"}' });
    expect(JSON.parse(await readFile(storePath, 'utf8')).observedAt).toBe(observedAt);
  });

  it('round-trips observed Claude and Codex windows through one combined usage read', async () => {
    const previous = {
      store: process.env.USAGE_STORE_PATH,
      claudeEnabled: process.env.CLAUDE_INGEST_ENABLED,
      claudeSecret: process.env.CLAUDE_INGEST_SECRET,
      claudeSecretFile: process.env.CLAUDE_INGEST_SECRET_FILE,
      codexEnabled: process.env.CODEX_INGEST_ENABLED,
      codexSecretFile: process.env.CODEX_INGEST_SECRET_FILE,
      codexLive: process.env.CODEX_LIVE_ENABLED,
    };
    const directory = await mkdtemp(join(tmpdir(), 'usage-dual-provider-'));
    const storePath = join(directory, 'history.jsonl');
    const claudeSecretPath = join(directory, 'claude.secret');
    const codexSecretPath = join(directory, 'codex.secret');
    const claudeSecret = 'c'.repeat(32);
    const codexSecret = 'x'.repeat(32);
    let server: ReturnType<typeof createApiServer> | undefined;
    try {
      process.env.USAGE_STORE_PATH = storePath;
      process.env.CLAUDE_INGEST_ENABLED = 'true';
      delete process.env.CLAUDE_INGEST_SECRET;
      process.env.CLAUDE_INGEST_SECRET_FILE = claudeSecretPath;
      process.env.CODEX_INGEST_ENABLED = 'true';
      process.env.CODEX_INGEST_SECRET_FILE = codexSecretPath;
      delete process.env.CODEX_LIVE_ENABLED;
      await writeFile(claudeSecretPath, claudeSecret, { mode: 0o600 });
      await writeFile(codexSecretPath, codexSecret, { mode: 0o600 });
      server = createApiServer();
      await listenApiServer(server);
      const address = server.address();
      if (!address || typeof address === 'string') throw Error('no address');

      const claude = await postClaudePayload(address.port, claudeSecret, {
        rate_limits: { five_hour: { used_percentage: 17, resets_at: 1_786_777_259 } },
      });
      const codex = await postCodexPayload(address.port, codexSecret, {
        windows: [{ minutes: 10_080, usedPercent: 29, resetAt: '2026-08-15T07:00:59Z' }],
      });
      const usage = await getUsage(address.port);

      expect(claude.status).toBe(200);
      expect(codex.status).toBe(200);
      expect(usage.status).toBe(200);
      expect(usage.body.connectors).toMatchObject({ claude: 'healthy', codex: 'healthy' });
      expect(usage.body.windows).toEqual(expect.arrayContaining([
        expect.objectContaining({ provider: 'claude', window: 'five_hour', usedPercent: 17,
          availability: 'observed', provenance: expect.objectContaining({ quality: 'observed' }) }),
        expect.objectContaining({ provider: 'codex', window: 'seven_day', usedPercent: 29,
          availability: 'observed', provenance: expect.objectContaining({ quality: 'observed' }) }),
      ]));
      const lines = (await readFile(storePath, 'utf8')).trim().split(/\r?\n/);
      expect(lines).toHaveLength(2);
    } finally {
      if (server) await closeApiServer(server);
      if (previous.store === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previous.store;
      if (previous.claudeEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previous.claudeEnabled;
      if (previous.claudeSecret === undefined) delete process.env.CLAUDE_INGEST_SECRET; else process.env.CLAUDE_INGEST_SECRET = previous.claudeSecret;
      if (previous.claudeSecretFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previous.claudeSecretFile;
      if (previous.codexEnabled === undefined) delete process.env.CODEX_INGEST_ENABLED; else process.env.CODEX_INGEST_ENABLED = previous.codexEnabled;
      if (previous.codexSecretFile === undefined) delete process.env.CODEX_INGEST_SECRET_FILE; else process.env.CODEX_INGEST_SECRET_FILE = previous.codexSecretFile;
      if (previous.codexLive === undefined) delete process.env.CODEX_LIVE_ENABLED; else process.env.CODEX_LIVE_ENABLED = previous.codexLive;
    }
  });

  it('returns a bounded 503 and preserves corrupt history bytes', async () => {
    const previousStore = process.env.USAGE_STORE_PATH;
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecret = process.env.CLAUDE_INGEST_SECRET;
    const previousSecretFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-claude-corrupt-'));
    const storePath = join(directory, 'history.jsonl');
    const secretPath = join(directory, 'secret');
    const secret = 'c'.repeat(32);
    const corrupt = '{not-json}\n';
    process.env.USAGE_STORE_PATH = storePath;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET_FILE = secretPath;
    delete process.env.CLAUDE_INGEST_SECRET;
    await writeFile(secretPath, secret, { mode: 0o600 });
    await writeFile(storePath, corrupt, { mode: 0o600 });
    const server = createApiServer(); await listenApiServer(server);
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const result = await postClaudePayload(address.port, secret, { rate_limits: {
      five_hour: { used_percentage: 12, resets_at: '2026-08-10T05:00:00Z' },
      seven_day: { used_percentage: 3, resets_at: '2026-08-17T00:00:00Z' },
    } });
    await new Promise(resolve => server.close(resolve));
    if (previousStore === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previousStore;
    if (previousEnabled === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousEnabled;
    if (previousSecret === undefined) delete process.env.CLAUDE_INGEST_SECRET; else process.env.CLAUDE_INGEST_SECRET = previousSecret;
    if (previousSecretFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousSecretFile;
    expect(result).toEqual({ status: 503, body: '{"error":"usage_store_unavailable"}' });
    expect(await readFile(storePath, 'utf8')).toBe(corrupt);
  });
});


describe('dedicated local service authentication', () => {
  async function call(path: string, method = 'GET', auth: string[] = [], address = LOOPBACK_HOST) {
    const req = Readable.from([Buffer.from('{}')]) as unknown as Parameters<typeof app>[0];
    Object.assign(req, { method, url: path, headers: { 'content-type': 'application/json' },
      rawHeaders: ['Content-Type', 'application/json', ...auth], socket: { remoteAddress: address } });
    let body = '';
    const res = { statusCode: 200, setHeader: () => undefined, end: (value: string) => { body = value; } };
    const live = vi.fn(async () => ({ connectorState: 'unavailable' as const, windows: [] }));
    const generate = vi.fn(async () => ({ accepted: true }));
    await app(req, res as never, live, undefined, undefined, { generate } as never);
    return { status: res.statusCode, body: JSON.parse(body), live, generate };
  }
  const valid = () => ['Authorization', `Bearer ${LOCAL_SECRET}`];

  it('protects every sensitive route before reading data or invoking providers', async () => {
    for (const [method, path] of SENSITIVE_LOCAL_ROUTES) {
      for (const auth of [[], ['Authorization', 'Bearer wrong'],
        ['Authorization', `Bearer ${'x'.repeat(LOCAL_SECRET.length)}`],
        [...valid(), ...valid()], [...valid(), 'authorization', 'Bearer wrong'],
        ['Authorization', `Bearer ${LOCAL_SECRET}, Bearer ${LOCAL_SECRET}`]]) {
        const result = await call(path, method, auth);
        expect(result.status, `${method} ${path}`).toBe(401);
        expect(result.body).toEqual({ error: 'unauthorized' });
        expect(result.live).not.toHaveBeenCalled(); expect(result.generate).not.toHaveBeenCalled();
      }
      const remote = await call(path, method, valid(), '100.100.100.100');
      expect(remote.status).toBe(403);
      expect(remote.live).not.toHaveBeenCalled(); expect(remote.generate).not.toHaveBeenCalled();
      const accepted = await call(path, method, valid());
      expect(accepted.status, path).toBe(200);
    }
  });

  it('rejects every method mismatch for protected paths before dispatch', async () => {
    const methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];
    for (const [expected, path] of SENSITIVE_LOCAL_ROUTES) {
      for (const method of methods) {
        if (method === expected) continue;
        const result = await call(path, method);
        expect(result.status, `${method} ${path}`).toBe(405);
        expect(result.body).toEqual({ error: 'read_only_api' });
        expect(result.live).not.toHaveBeenCalled();
        expect(result.generate).not.toHaveBeenCalled();
      }
    }
  });

  it('preserves authenticated cached Codex reads without invoking live access or writing history', async () => {
    const store = join(localDirectory, 'cached-history');
    vi.stubEnv('USAGE_STORE_PATH', store);
    vi.stubEnv('CODEX_LIVE_ENABLED', 'false');
    for (const age of [60_000, 60 * 60_000]) {
      const bytes = JSON.stringify({ provider: 'codex', window: 'five_hour', durationMinutes: 300,
        usedPercent: 12, observedAt: new Date(Date.now() - age).toISOString() }) + '\n';
      await writeFile(store, bytes, { mode: 0o600 });
      const result = await call('/api/usage', 'GET', valid());
      expect(result.status).toBe(200);
      expect(result.body.connectors.codex).toBe(age === 60_000 ? 'healthy' : 'refresh_due');
      expect(result.body.windows[0].usedPercent).toBe(12);
      expect(result.live).not.toHaveBeenCalled();
      expect(await readFile(store, 'utf8')).toBe(bytes);
    }
  });

  it('accepts loopback variants and rejects normalized duplicate headers over real HTTP', async () => {
    for (const address of ['127.0.0.1', '::1', '::ffff:127.0.0.1'])
      expect((await call('/api/codex/live', 'GET', valid(), address)).status).toBe(200);
    const server = createApiServer(async () => ({ connectorState: 'unavailable', windows: [] }));
    await listenApiServer(server);
    try {
      const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
      const status = await new Promise<number>((resolve, reject) => {
        const req = request({ host: LOOPBACK_HOST, port: address.port, path: '/api/codex/live',
          headers: ['Host', 'localhost', ...valid(), 'aUtHoRiZaTiOn', `Bearer ${LOCAL_SECRET}`] }, res => {
          res.resume(); res.on('end', () => resolve(res.statusCode!));
        });
        req.on('error', reject); req.end();
      });
      expect(status).toBe(401);
    } finally { await closeApiServer(server); }
    const req = { socket: { remoteAddress: LOOPBACK_HOST }, headers: { authorization: [`Bearer ${LOCAL_SECRET}`, `Bearer ${LOCAL_SECRET}`] } };
    expect(await authorizeLocalApi(req as never)).toBe(401);
  });

  it('leaves public/status, static, unknown and separately authenticated routes independent', async () => {
    vi.stubEnv('USAGE_STORE_PATH', join(localDirectory, 'history'));
    vi.stubEnv('LIFEOS_LOCAL_API_ENABLED', 'false');
    for (const path of ['/health', '/ready', '/api/overview', '/api/codex', '/api/finance/connectors', '/api/finance/summary'])
      expect((await call(path)).status, path).toBe(200);
    expect((await call('/health', 'GET', [], '192.0.2.1')).status).toBe(200);
    expect((await call('/ready', 'GET', [], '192.0.2.1')).status).toBe(200);
    expect((await call('/api/calendar')).status).toBe(503);
    expect((await call('/api/nutrition/summary')).status).toBe(404);
    expect((await call('/missing')).status).toBe(404);
    expect((await call('/api/usage', 'POST')).status).toBe(405);
    for (const [enabled, file, path] of [
      ['CLAUDE_INGEST_ENABLED', 'CLAUDE_INGEST_SECRET_FILE', '/api/usage/claude-ingest'],
      ['CLAUDE_STATUSLINE_ENABLED', 'CLAUDE_INGEST_SECRET_FILE', '/api/claude/statusline'],
      ['CODEX_INGEST_ENABLED', 'CODEX_INGEST_SECRET_FILE', '/api/usage/codex-ingest'],
      ['CLIPPER_INGEST_ENABLED', 'CLIPPER_INGEST_SECRET_FILE', '/api/clipper/ingest'],
    ]) {
      const pathValue = join(localDirectory, file);
      const collectorSecret = file.repeat(3);
      await writeFile(pathValue, collectorSecret, { mode: 0o600 });
      vi.stubEnv(enabled, 'true'); vi.stubEnv(file, pathValue);
      expect((await call(path, 'POST', valid())).status).toBe(401);
      const result = await call(path, 'POST', ['Authorization', `Bearer ${collectorSecret}`]);
      expect([400, 422]).toContain(result.status); // passed auth; missing idempotency/invalid body
    }
  });

  it('fails startup and readiness for missing or malformed enabled credentials without leaking values', async () => {
    vi.stubEnv('USAGE_STORE_PATH', join(localDirectory, 'history'));
    const path = process.env.LIFEOS_LOCAL_API_SECRET_FILE!;
    expect(await validateStartupConfiguration()).toBe(true);
    for (const value of ['', 'short', 'x'.repeat(257), 'x'.repeat(4097), `${LOCAL_SECRET}\n`, 'é'.repeat(40)]) {
      await writeFile(path, value, { mode: 0o600 });
      expect(await validateStartupConfiguration()).toBe(false);
      expect((await call('/ready')).status).toBe(503);
      expect(await call('/health')).toMatchObject({ status: 200, body: { readiness: 'unavailable' } });
      expect(await call('/api/codex/live', 'GET', valid())).toMatchObject({ status: 503, body: { error: 'local_api_unavailable' } });
      await expect(startApiServer({ port: 0 })).rejects.toThrow('startup_configuration_invalid');
    }
    await unlink(path);
    expect(await validateStartupConfiguration()).toBe(false);
    vi.stubEnv('LIFEOS_LOCAL_API_SECRET', LOCAL_SECRET);
    vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', undefined);
    expect(await validateStartupConfiguration()).toBe(false);
    vi.stubEnv('LIFEOS_LOCAL_API_ENABLED', 'false');
    expect(await validateStartupConfiguration()).toBe(true);
    expect((await call('/api/codex/live', 'GET', valid())).status).toBe(503);
    vi.stubEnv('LIFEOS_LOCAL_API_ENABLED', 'typo');
    expect(await validateStartupConfiguration()).toBe(false);
    vi.stubEnv('LIFEOS_LOCAL_API_ENABLED', undefined);
    expect((await call('/api/codex/live', 'GET', valid())).status).toBe(503);
    await writeFile(path, LOCAL_SECRET, { mode: 0o600 });
    vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', path);
    expect((await call('/api/codex/live', 'GET', valid())).status).toBe(200);
  });

  it('rejects relative paths, directories, symlinks and permissive files and honors rotation', async () => {
    vi.stubEnv('USAGE_STORE_PATH', join(localDirectory, 'history'));
    const path = process.env.LIFEOS_LOCAL_API_SECRET_FILE!;
    for (const invalid of ['relative.secret', localDirectory, join(localDirectory, 'absent')]) {
      vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', invalid);
      expect(await validateStartupConfiguration()).toBe(false);
    }
    vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', path);
    if (process.platform !== 'win32') {
      await chmod(path, 0o644); expect(await validateStartupConfiguration()).toBe(false);
      await chmod(path, 0o600);
      const link = join(localDirectory, 'link'); await symlink(path, link);
      vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', link); expect(await validateStartupConfiguration()).toBe(false);
      vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', path);
    }
    await writeFile(path, 'r'.repeat(48));
    expect((await call('/api/codex/live', 'GET', valid())).status).toBe(401);
    expect((await call('/api/codex/live', 'GET', ['Authorization', `Bearer ${'r'.repeat(48)}`])).status).toBe(200);
  });
});
