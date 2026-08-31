import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { EventEmitter } from 'node:events';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startApiServer, type ApiRuntime } from './server.js';

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

describe('API startup lifecycle', () => {
  it('drains and closes the loopback listener on redirected stdin EOF without exiting Vitest', async () => {
    const previousStore = process.env.USAGE_STORE_PATH;
    const directory = await mkdtemp(join(tmpdir(), 'usage-startup-'));
    const runtime = fakeRuntime();
    process.env.USAGE_STORE_PATH = join(directory, 'history.jsonl');
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
});
