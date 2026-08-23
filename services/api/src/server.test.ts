import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { chmod, mkdtemp, mkdir, readFile, rmdir, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApiServer } from './server.js';

const postClaudeIngest = (port: number, secret: string) => new Promise<{ status: number; body: string }>(resolve => {
  const req = request({ port, path: '/api/usage/claude-ingest', method: 'POST', headers: {
    authorization: `Bearer ${secret}`, 'content-type': 'application/json',
  } }, response => { let value = ''; response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: value })); });
  req.end('{}');
});
const postClaudePayload = (port: number, secret: string, payload: unknown) => new Promise<{ status: number; body: string }>(resolve => {
  const req = request({ port, path: '/api/usage/claude-ingest', method: 'POST', headers: {
    authorization: `Bearer ${secret}`, 'content-type': 'application/json',
  } }, response => { let value = ''; response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: value })); });
  req.end(JSON.stringify(payload));
});
const listenApiServer = (server: ReturnType<typeof createApiServer>) => new Promise<void>((resolve, reject) => {
  const onError = (error: Error) => { server.removeListener('error', onError); reject(error); };
  server.once('error', onError);
  server.listen(0, () => { server.removeListener('error', onError); resolve(); });
});
const closeApiServer = (server: ReturnType<typeof createApiServer>) => new Promise<void>(resolve => {
  if (!server.listening) { resolve(); return; }
  server.close(() => resolve());
});

describe('HTTP API', () => {
  it('ignores inline Claude secrets when no secret file is configured', async () => {
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecret = process.env.CLAUDE_INGEST_SECRET;
    const previousStatuslineToken = process.env.CLAUDE_STATUSLINE_TOKEN;
    const previousSecretFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET = 'a'.repeat(32);
    process.env.CLAUDE_STATUSLINE_TOKEN = 'b'.repeat(32);
    delete process.env.CLAUDE_INGEST_SECRET_FILE;
    const server = createApiServer(); await new Promise<void>(resolve => server.listen(0, resolve));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const result = await new Promise<{ status: number; body: { error?: string } }>(resolve => {
      const req = request({ port: address.port, path: '/api/usage/claude-ingest', method: 'POST', headers: {
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
    const server = createApiServer(); await new Promise<void>(resolve => server.listen(0, resolve));
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
    const server = createApiServer(); await new Promise<void>(resolve => server.listen(0, resolve));
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
    const server = createApiServer(); await new Promise<void>(resolve => server.listen(0, resolve));
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
      const call = (path:string, method='GET') => new Promise<{status:number; body:any}>(resolve => { const req=request({port:address.port,path,method}, res=>{let b='';res.on('data',x=>b+=x);res.on('end',()=>resolve({status:res.statusCode!,body:JSON.parse(b)}))});req.end(); });
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
        'sparkasse',
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
        const req = request({ port: address.port, path }, response => {
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
    const server = createApiServer(); await new Promise<void>(r => server.listen(0, r));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const result = await new Promise<{ status: number; body: { connectors: { claude: string }; windows: unknown[] } }>(resolve => {
      const req = request({ port: address.port, path: '/api/usage' }, res => {
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
    await new Promise<void>(resolve => server.listen(0, resolve));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const body = await new Promise<{ connectors: { claude: string }; windows: Array<{ provider: string; provenance: { connectorState: string } }> }>(resolve => {
      const req = request({ port: address.port, path: '/api/usage' }, response => {
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
    await new Promise<void>(resolve => server.listen(0, resolve));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    await new Promise<void>(resolve => {
      const req = request({ port: address.port, path: '/api/usage' }, response => { response.resume(); response.on('end', resolve); });
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
    await new Promise<void>(resolve => server.listen(0, resolve));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const body = await new Promise<{ windows: Array<{ provider: string; window: string; usedPercent?: number }> }>(resolve => {
      const req = request({ port: address.port, path: '/api/usage' }, response => {
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
    await new Promise<void>(resolve => server.listen(0, resolve));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const body = await new Promise<{ windows: unknown[] }>(resolve => {
      const req = request({ port: address.port, path: '/api/usage' }, response => {
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
    const server = createApiServer(); await new Promise<void>(resolve => server.listen(0, resolve));
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
    const server = createApiServer(); await new Promise<void>(resolve => server.listen(0, resolve));
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
