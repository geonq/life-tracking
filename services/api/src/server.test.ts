import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApiServer } from './server.js';

describe('HTTP API', () => {
  it('rejects Claude ingestion when parsing yields no observed usage', async () => {
    const previousEnabled = process.env.CLAUDE_INGEST_ENABLED;
    const previousSecret = process.env.CLAUDE_INGEST_SECRET;
    process.env.CLAUDE_INGEST_ENABLED = 'true';
    process.env.CLAUDE_INGEST_SECRET = 'a'.repeat(32);
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
    expect(result).toEqual({ status: 422, body: { error: 'usage_unavailable' } });
  });
  it('serves health, overview and codex, rejects methods and unknown paths', async () => {
    const server = createApiServer(); await new Promise<void>(r => server.listen(0, r));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const call = (path:string, method='GET') => new Promise<{status:number; body:any}>(resolve => { const req=request({port:address.port,path,method}, res=>{let b='';res.on('data',x=>b+=x);res.on('end',()=>resolve({status:res.statusCode!,body:JSON.parse(b)}))});req.end(); });
    expect((await call('/health')).body.status).toBe('ok');
    expect((await call('/api/overview')).body.label).toBe('Demo data');
    expect((await call('/api/codex')).body.kind).toBe('codex');

    const finance = await call('/api/finance/connectors');
    expect(finance.status).toBe(200);
    expect(finance.body.connectors.map((connector: { id: string }) => connector.id)).toEqual([
      'sparkasse',
      'paypal',
      'trade_republic',
    ]);
    expect(finance.body.connectors.every((connector: { enabled: boolean }) => !connector.enabled)).toBe(true);
    expect(finance.body.connectors.find((connector: { id: string }) => connector.id === 'trade_republic').risk).toBe('experimental_only');

    const financeSummary = await call('/api/finance/summary');
    expect(financeSummary.status).toBe(200);
    expect(financeSummary.body.currency).toBe('EUR');
    for (const key of ['monthlyIncome', 'fixedCosts', 'discretionaryBuffer', 'spent', 'savingsGoal', 'saved']) {
      expect(financeSummary.body[key]).toMatchObject({ availability: 'unavailable', provenance: { quality: 'unavailable', connectorState: 'unavailable' } });
      expect(financeSummary.body[key]).not.toHaveProperty('amountCents');
    }

    expect((await call('/missing')).status).toBe(404);
    expect((await call('/health','POST')).status).toBe(405);
    await new Promise(r=>server.close(r));
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
    const directory = await mkdtemp(join(tmpdir(), 'usage-dedupe-'));
    const storePath = join(directory, 'history.jsonl');
    process.env.USAGE_STORE_PATH = storePath;
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
});
