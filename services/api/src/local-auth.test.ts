import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { authorizeLocalApi, localApiConfigurationReady, constantTimeCredentialEqual } from './local-auth.js';
import { startApiServer, validateStartupConfiguration } from './server.js';

const secret = 'local-test-credential-'.repeat(3);
let directory: string;
let local: string;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'local-auth-isolation-'));
  local = join(directory, 'local');
  await writeFile(local, secret, { mode: 0o600 });
  vi.stubEnv('LIFEOS_LOCAL_API_ENABLED', 'true');
  vi.stubEnv('LIFEOS_LOCAL_API_SECRET_FILE', local);
  vi.stubEnv('USAGE_STORE_PATH', join(directory, 'history'));
});

afterEach(async () => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  await rm(directory, { recursive: true, force: true });
});

const req = () => ({
  method: 'GET',
  url: '/api/usage',
  socket: { remoteAddress: '127.0.0.1' },
  headers: {},
  rawHeaders: ['Authorization', `Bearer ${secret}`],
});

describe('local credential configuration', () => {
  it('compares credential digests for equal and unequal lengths', () => {
    expect(constantTimeCredentialEqual(secret, secret)).toBe(true);
    for (const other of ['', secret.slice(1), secret + 'x', 'x'.repeat(secret.length)]) {
      expect(constantTimeCredentialEqual(secret, other)).toBe(false);
    }
  });

  it.each(['same-path', 'same-value'])('fails closed for collector credential reuse: %s', async kind => {
    const collector = join(directory, 'collector');
    const environment = 'CODEX_INGEST_SECRET_FILE';
    vi.stubEnv(environment, kind === 'same-path' ? local : collector);
    if (kind === 'same-value') await writeFile(collector, secret, { mode: 0o600 });

    expect(await localApiConfigurationReady()).toBe(false);
    expect(await authorizeLocalApi(req() as never)).toBe(503);
    expect(await validateStartupConfiguration()).toBe(false);
    await expect(startApiServer({ port: 0 })).rejects.toThrow('startup_configuration_invalid');
  });

  it.each(['CODEX_INGEST_SECRET_FILE', 'CLAUDE_INGEST_SECRET_FILE', 'CLIPPER_INGEST_SECRET_FILE'])('rejects invalid collector credentials: %s', async environment => {
    const collector = join(directory, 'collector');
    vi.stubEnv(environment, collector);
    for (const value of ['short', secret + '\n']) {
      await writeFile(collector, value, { mode: 0o600 });
      expect(await localApiConfigurationReady()).toBe(false);
      expect(await validateStartupConfiguration()).toBe(false);
      await expect(startApiServer({ port: 0 })).rejects.toThrow('startup_configuration_invalid');
    }
    vi.stubEnv(environment, undefined);
    expect(await localApiConfigurationReady()).toBe(true);
    expect(await authorizeLocalApi(req() as never)).toBeUndefined();
  });

  it.each(['CODEX_INGEST_SECRET_FILE', 'CLAUDE_INGEST_SECRET_FILE', 'CLIPPER_INGEST_SECRET_FILE'])('accepts and rechecks distinct collector credentials: %s', async environment => {
    const collector = join(directory, 'collector');
    const collectorSecret = 'collector-test-credential-'.repeat(3);
    vi.stubEnv(environment, collector);
    await writeFile(collector, collectorSecret, { mode: 0o600 });
    expect(await localApiConfigurationReady()).toBe(true);
    expect(await authorizeLocalApi(req() as never)).toBeUndefined();

    await writeFile(collector, secret, { mode: 0o600 });
    expect(await localApiConfigurationReady()).toBe(false);
    expect(await authorizeLocalApi(req() as never)).toBe(503);
  });
});
