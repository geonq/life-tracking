import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { chmod, mkdir, mkdtemp, readFile, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApiServer, validateStartupConfiguration } from './server.js';
import { main as collectorMain, postCodexPayload, runCodexCollector } from './codex-collector.js';

type ResponseValue = { status: number; body: string };
const post = (port: number, secret: string, payload: string, contentType = 'application/json') => new Promise<ResponseValue>(resolve => {
  const req = request({ port, path: '/api/usage/codex-ingest', method: 'POST', headers: {
    authorization: `Bearer ${secret}`, 'content-type': contentType, 'content-length': Buffer.byteLength(payload),
  } }, response => {
    let value = '';
    response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: value }));
  });
  req.on('error', () => resolve({ status: 599, body: '' }));
  req.setTimeout(5_000, () => { req.destroy(); resolve({ status: 598, body: '' }); });
  req.end(payload);
});
const getUsage = (port: number) => new Promise<{ status: number; body: any }>(resolve => {
  const req = request({ port, path: '/api/usage', method: 'GET' }, response => {
    let value = '';
    response.on('data', chunk => value += chunk);
    response.on('end', () => resolve({ status: response.statusCode!, body: JSON.parse(value) }));
  });
  req.on('error', () => resolve({ status: 599, body: {} }));
  req.setTimeout(5_000, () => { req.destroy(); resolve({ status: 598, body: {} }); });
  req.end();
});

async function configuredServer(readLive: Parameters<typeof createApiServer>[0] = async () => ({ connectorState: 'unavailable', windows: [] })) {
  const previous = {
    enabled: process.env.CODEX_INGEST_ENABLED,
    secretFile: process.env.CODEX_INGEST_SECRET_FILE,
    store: process.env.USAGE_STORE_PATH,
    live: process.env.CODEX_LIVE_ENABLED,
    claude: process.env.CLAUDE_INGEST_ENABLED,
    statusline: process.env.CLAUDE_STATUSLINE_ENABLED,
  };
  const directory = await mkdtemp(join(tmpdir(), 'usage-codex-ingest-'));
  const secretPath = join(directory, 'codex.secret');
  const storePath = join(directory, 'history.jsonl');
  const secret = 'c'.repeat(32);
  const restore = () => {
    if (previous.enabled === undefined) delete process.env.CODEX_INGEST_ENABLED; else process.env.CODEX_INGEST_ENABLED = previous.enabled;
    if (previous.secretFile === undefined) delete process.env.CODEX_INGEST_SECRET_FILE; else process.env.CODEX_INGEST_SECRET_FILE = previous.secretFile;
    if (previous.store === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previous.store;
    if (previous.live === undefined) delete process.env.CODEX_LIVE_ENABLED; else process.env.CODEX_LIVE_ENABLED = previous.live;
    if (previous.claude === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previous.claude;
    if (previous.statusline === undefined) delete process.env.CLAUDE_STATUSLINE_ENABLED; else process.env.CLAUDE_STATUSLINE_ENABLED = previous.statusline;
  };
  let server: ReturnType<typeof createApiServer> | undefined;
  try {
    process.env.CODEX_INGEST_ENABLED = 'true';
    process.env.CODEX_INGEST_SECRET_FILE = secretPath;
    process.env.USAGE_STORE_PATH = storePath;
    delete process.env.CODEX_LIVE_ENABLED;
    delete process.env.CLAUDE_INGEST_ENABLED;
    delete process.env.CLAUDE_STATUSLINE_ENABLED;
    await writeFile(secretPath, secret, { mode: 0o600 });
    server = createApiServer(readLive);
    await new Promise<void>((resolve, reject) => { server!.once('error', reject); server!.listen(0, resolve); });
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('no address');
    return {
      port: address.port, secret, storePath, server,
      restore,
    };
  } catch (error) {
    if (server) await new Promise<void>(resolve => server!.close(() => resolve()));
    restore();
    throw error;
  }
}

describe('sanitized Codex collector boundary', () => {
  it('accepts only an absolute secret-file task argument and keeps env fallback intact', async () => {
    const previousArgv = process.argv;
    const previousSecretFile = process.env.CODEX_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-collector-args-'));
    const secretPath = join(directory, 'codex.secret');
    try {
      await writeFile(secretPath, 'd'.repeat(32), { mode: 0o600 });
      process.argv = ['node', 'codex-collector', '--secret-file', secretPath];
      process.env.CODEX_INGEST_SECRET_FILE = join(directory, 'missing-secret');
      // The live app-server is intentionally unavailable in this test. A
      // valid path must therefore get as far as the collector read, not fail
      // argument parsing; main reports the bounded unavailable result.
      expect(await collectorMain()).toBe(1);
      process.argv = ['node', 'codex-collector', '--secret-file', 'relative.secret'];
      expect(await collectorMain()).toBe(1);
    } finally {
      process.argv = previousArgv;
      if (previousSecretFile === undefined) delete process.env.CODEX_INGEST_SECRET_FILE;
      else process.env.CODEX_INGEST_SECRET_FILE = previousSecretFile;
    }
  });

  it('rejects wrong credentials and every malformed/extra/type/duplicate shape without writing', async () => {
    const fixture = await configuredServer();
    const valid = JSON.stringify({ windows: [{ minutes: 300, usedPercent: 12, resetAt: '2026-08-12T05:00:00Z' }] });
    const cases: Array<[string, string, string]> = [
      ['wrong secret', 'x'.repeat(32), valid],
      ['duplicate windows', fixture.secret, JSON.stringify({ windows: [
        { minutes: 300, usedPercent: 12 }, { minutes: 300, usedPercent: 13 },
      ] })],
      ['sensitive sibling', fixture.secret, JSON.stringify({ windows: [{ minutes: 300, usedPercent: 12, prompt: 'do not persist' }] })],
      ['extra top-level field', fixture.secret, JSON.stringify({ windows: [{ minutes: 300, usedPercent: 12 }], account: 'private' })],
      ['wrong type', fixture.secret, JSON.stringify({ windows: [{ minutes: '300', usedPercent: 12 }] })],
      ['malformed', fixture.secret, '{"windows":'],
    ];
    try {
      expect((await post(fixture.port, ...cases[0]!.slice(1) as [string, string])).status).toBe(401);
      for (const [, secret, payload] of cases.slice(1)) {
        const result = await post(fixture.port, secret, payload);
        expect(result.status).toBe(400);
        expect(result.body).toBe('{"error":"invalid_request"}');
      }
      expect((await post(fixture.port, fixture.secret, valid, 'text/plain')).status).toBe(415);
      const oversized = await post(fixture.port, fixture.secret, 'x'.repeat(16_385));
      expect(oversized.status).toBe(413);
      expect(oversized.body).toBe('{"error":"invalid_request"}');
      await expect(readFile(fixture.storePath, 'utf8')).rejects.toMatchObject({ code: 'ENOENT' });
    } finally {
      await new Promise(resolve => fixture.server.close(resolve));
      fixture.restore();
    }
  });

  it('atomically accepts and deduplicates a replay, persisting only supported fields', async () => {
    const fixture = await configuredServer();
    const payload = JSON.stringify({ windows: [
      { minutes: 300, usedPercent: 12, resetAt: '2026-08-12T05:00:00Z' },
      { minutes: 10_080, usedPercent: 34 },
    ] });
    try {
      expect((await post(fixture.port, fixture.secret, payload)).status).toBe(200);
      expect((await post(fixture.port, fixture.secret, payload)).status).toBe(200);
      const text = await readFile(fixture.storePath, 'utf8');
      const entries = text.trim().split(/\r?\n/).map(line => JSON.parse(line));
      expect(entries).toHaveLength(2);
      expect(text).not.toMatch(/prompt|account|path|token|secret/);
      expect(entries.map((entry: { window: string }) => entry.window)).toEqual(['five_hour', 'seven_day']);
    } finally {
      await new Promise(resolve => fixture.server.close(resolve));
      fixture.restore();
    }
  });

  it('returns a bounded unavailable error when the store cannot be written', async () => {
    const fixture = await configuredServer();
    process.env.USAGE_STORE_PATH = fixture.storePath + '.missing/..';
    try {
      const result = await post(fixture.port, fixture.secret, JSON.stringify({ windows: [{ minutes: 300, usedPercent: 1 }] }));
      expect(result).toEqual({ status: 503, body: '{"error":"unavailable"}' });
    } finally {
      await new Promise(resolve => fixture.server.close(resolve));
      fixture.restore();
    }
  });

  it('uses cached Codex observations when direct live access is disabled, without making GET a writer', async () => {
    const fixture = await configuredServer(async () => { throw new Error('direct live should be gated'); });
    const fresh = new Date(Date.now() - 60_000).toISOString();
    await writeFile(fixture.storePath, JSON.stringify({ provider: 'codex', window: 'five_hour', durationMinutes: 300, usedPercent: 12, observedAt: fresh }) + '\n');
    try {
      const healthy = await getUsage(fixture.port);
      expect(healthy.status).toBe(200);
      expect(healthy.body.connectors.codex).toBe('healthy');
      expect(healthy.body.windows.find((window: { provider: string }) => window.provider === 'codex').usedPercent).toBe(12);
      const metadataBeforeGet = await stat(fixture.storePath);
      const before = await readFile(fixture.storePath, 'utf8');
      const repeated = await getUsage(fixture.port);
      expect(repeated.status).toBe(200);
      expect((await stat(fixture.storePath)).mtimeMs).toBe(metadataBeforeGet.mtimeMs);
      const stale = new Date(Date.now() - 60 * 60_000).toISOString();
      await writeFile(fixture.storePath, JSON.stringify({ provider: 'codex', window: 'five_hour', durationMinutes: 300, usedPercent: 13, observedAt: stale }) + '\n');
      const refreshDue = await getUsage(fixture.port);
      expect(refreshDue.body.connectors.codex).toBe('refresh_due');
      expect(refreshDue.body.windows.find((window: { provider: string }) => window.provider === 'codex').provenance.connectorState).toBe('refresh_due');
      expect(before).not.toBe('');
      expect(await readFile(fixture.storePath, 'utf8')).toContain('"usedPercent":13');
    } finally {
      await new Promise(resolve => fixture.server.close(resolve));
      fixture.restore();
    }
  });

  it('validates every enabled ingestion secret at readiness', async () => {
    const previousCodex = process.env.CODEX_INGEST_ENABLED;
    const previousClaude = process.env.CLAUDE_INGEST_ENABLED;
    const previousCodexFile = process.env.CODEX_INGEST_SECRET_FILE;
    const previousClaudeFile = process.env.CLAUDE_INGEST_SECRET_FILE;
    const directory = await mkdtemp(join(tmpdir(), 'usage-readiness-'));
    try {
      process.env.CODEX_INGEST_ENABLED = 'true';
      process.env.CLAUDE_INGEST_ENABLED = 'true';
      process.env.CODEX_INGEST_SECRET_FILE = join(directory, 'codex');
      process.env.CLAUDE_INGEST_SECRET_FILE = join(directory, 'claude');
      await writeFile(process.env.CODEX_INGEST_SECRET_FILE, 'x'.repeat(32), { mode: 0o600 });
      expect(await validateStartupConfiguration()).toBe(false);
      await writeFile(process.env.CLAUDE_INGEST_SECRET_FILE, 'y'.repeat(32), { mode: 0o600 });
      expect(await validateStartupConfiguration()).toBe(true);
    } finally {
      if (previousCodex === undefined) delete process.env.CODEX_INGEST_ENABLED; else process.env.CODEX_INGEST_ENABLED = previousCodex;
      if (previousClaude === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previousClaude;
      if (previousCodexFile === undefined) delete process.env.CODEX_INGEST_SECRET_FILE; else process.env.CODEX_INGEST_SECRET_FILE = previousCodexFile;
      if (previousClaudeFile === undefined) delete process.env.CLAUDE_INGEST_SECRET_FILE; else process.env.CLAUDE_INGEST_SECRET_FILE = previousClaudeFile;
    }
  });

  it('fails readiness for unsafe/relative/corrupt stores without creating or truncating history', async () => {
    const previous = {
      usage: process.env.USAGE_STORE_PATH,
      codex: process.env.CODEX_INGEST_ENABLED,
      claude: process.env.CLAUDE_INGEST_ENABLED,
      statusline: process.env.CLAUDE_STATUSLINE_ENABLED,
    };
    const directory = await mkdtemp(join(tmpdir(), 'usage-store-readiness-'));
    try {
      delete process.env.CODEX_INGEST_ENABLED;
      delete process.env.CLAUDE_INGEST_ENABLED;
      delete process.env.CLAUDE_STATUSLINE_ENABLED;
      process.env.USAGE_STORE_PATH = 'relative-history.jsonl';
      expect(await validateStartupConfiguration()).toBe(false);
      process.env.USAGE_STORE_PATH = join(directory, 'missing-parent', 'history.jsonl');
      expect(await validateStartupConfiguration()).toBe(false);
      const safePath = join(directory, 'history.jsonl');
      process.env.USAGE_STORE_PATH = safePath;
      expect(await validateStartupConfiguration()).toBe(true);
      await writeFile(safePath, '{not-json}\n', { mode: 0o600 });
      await chmod(safePath, 0o600);
      expect(await validateStartupConfiguration()).toBe(false);
      if (process.platform !== 'win32') {
        const readOnlyParent = join(directory, 'read-only-parent');
        await mkdir(readOnlyParent);
        await chmod(readOnlyParent, 0o500);
        try {
          process.env.USAGE_STORE_PATH = join(readOnlyParent, 'history.jsonl');
          expect(await validateStartupConfiguration()).toBe(false);
        } finally {
          await chmod(readOnlyParent, 0o700);
        }
        const readOnlyStore = join(directory, 'read-only-history.jsonl');
        await writeFile(readOnlyStore, JSON.stringify({ provider: 'codex', window: 'five_hour', durationMinutes: 300, usedPercent: 1, observedAt: new Date().toISOString() }) + '\n', { mode: 0o600 });
        await chmod(readOnlyStore, 0o400);
        try {
          process.env.USAGE_STORE_PATH = readOnlyStore;
          expect(await validateStartupConfiguration()).toBe(false);
        } finally {
          await chmod(readOnlyStore, 0o600);
        }
      }
      const target = join(directory, 'target');
      const linkParent = join(directory, 'linked-parent');
      await writeFile(target, JSON.stringify({ provider: 'codex', window: 'five_hour', durationMinutes: 300, usedPercent: 1, observedAt: new Date().toISOString() }) + '\n', { mode: 0o600 });
      await chmod(target, 0o600);
      const parentDirectory = join(directory, 'real-parent');
      const linkedStore = join(linkParent, 'history.jsonl');
      await mkdir(parentDirectory);
      await symlink(parentDirectory, linkParent);
      process.env.USAGE_STORE_PATH = linkedStore;
      expect(await validateStartupConfiguration()).toBe(false);
      expect(await readFile(target, 'utf8')).toContain('"usedPercent":1');
    } finally {
      if (previous.usage === undefined) delete process.env.USAGE_STORE_PATH; else process.env.USAGE_STORE_PATH = previous.usage;
      if (previous.codex === undefined) delete process.env.CODEX_INGEST_ENABLED; else process.env.CODEX_INGEST_ENABLED = previous.codex;
      if (previous.claude === undefined) delete process.env.CLAUDE_INGEST_ENABLED; else process.env.CLAUDE_INGEST_ENABLED = previous.claude;
      if (previous.statusline === undefined) delete process.env.CLAUDE_STATUSLINE_ENABLED; else process.env.CLAUDE_STATUSLINE_ENABLED = previous.statusline;
    }
  });

  it('collector strips app-server siblings and reports network failure generically', async () => {
    const posted: Array<{ windows: unknown[] }> = [];
    await runCodexCollector({
      secret: async () => 's'.repeat(32),
      read: async () => ({ connectorState: 'healthy', windows: [{ minutes: 300, usedPercent: 22, resetAt: '2026-08-12T05:00:00.000Z', prompt: 'private' } as never] }),
      post: async payload => posted.push(payload),
    });
    expect(posted).toEqual([{ windows: [{ minutes: 300, usedPercent: 22, resetAt: '2026-08-12T05:00:00.000Z' }] }]);
    await expect(postCodexPayload({ windows: [{ minutes: 300, usedPercent: 1 }] }, 's'.repeat(32), 1)).rejects.toThrow('collector_unavailable');
  });
});
