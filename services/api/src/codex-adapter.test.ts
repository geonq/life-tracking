import { EventEmitter } from 'node:events';
import type { ChildProcess } from 'node:child_process';
import { describe, expect, it, vi } from 'vitest';
import { CodexRpcError, codexSpawnSpec, createCodexTransport, readCodexAppServer, readCodexLive, type Transport } from './codex-adapter.js';

function transportFor(handler: (method: string) => Promise<unknown>): { transport: Transport; close: ReturnType<typeof vi.fn> } {
  const close = vi.fn();
  const transport = (async (request: Record<string, unknown>) => handler(String(request.method))) as Transport;
  transport.close = close;
  return { transport, close };
}

describe('Codex app-server boundary', () => {
  it('requires explicit absolute regular files and rejects unsafe resolution without process creation', async () => {
    const isRegularFile = vi.fn(() => true);
    expect(codexSpawnSpec({
      platform: 'win32', systemRoot: 'C:\\Windows', shellPath: 'C:\\Windows\\System32\\cmd.exe',
      executablePath: 'C:\\Program Files\\Codex\\codex.cmd', isRegularFile,
    })).toEqual({ command: 'C:\\Windows\\System32\\cmd.exe', args: ['/d', '/s', '/c', '""C:\\Program Files\\Codex\\codex.cmd" app-server"'] });
    expect(codexSpawnSpec({
      platform: 'win32', systemRoot: 'C:\\Windows',
      executablePath: 'C:\\Program Files\\Codex\\codex.exe', isRegularFile,
    })).toEqual({ command: 'C:\\Program Files\\Codex\\codex.exe', args: ['app-server'] });
    // A planted prefix or suffix must never become the executable selected by
    // basename matching, even when the injected file predicate says it exists.
    expect(codexSpawnSpec({
      platform: 'win32', systemRoot: 'C:\\Windows',
      executablePath: 'C:\\Program Files\\Codex\\codex.cmd.bak', isRegularFile: () => true,
    })).toBeUndefined();
    expect(codexSpawnSpec({
      platform: 'win32', systemRoot: 'C:\\Windows', shellPath: 'cmd.exe',
      executablePath: 'C:\\Program Files\\Codex\\codex.cmd', isRegularFile,
    })).toBeUndefined();
    // A writable working directory must never supply the executable through
    // PATH or a relative .cmd name.
    expect(codexSpawnSpec({
      platform: 'win32', systemRoot: 'C:\\Windows', shellPath: 'C:\\Windows\\System32\\cmd.exe',
      executablePath: 'codex.cmd', isRegularFile,
    })).toBeUndefined();
    expect(codexSpawnSpec({
      platform: 'darwin', executablePath: './codex', isRegularFile,
    })).toBeUndefined();
    expect(codexSpawnSpec({
      platform: 'darwin', executablePath: 42 as never, isRegularFile,
    })).toBeUndefined();
    expect(codexSpawnSpec({
      platform: 'win32', systemRoot: 'C:\\Windows', shellPath: 'C:\\Windows\\System32\\cmd.exe',
      executablePath: 'C:\\Program Files\\Codex\\codex.cmd', isRegularFile: () => false,
    })).toBeUndefined();
    expect(codexSpawnSpec({ platform: 'win32', executablePath: 'C:\\Temp\\other.cmd', isRegularFile })).toBeUndefined();
    expect(codexSpawnSpec({ platform: 'darwin', executablePath: 'codex', isRegularFile })).toBeUndefined();
    expect(isRegularFile).toHaveBeenCalledTimes(4);

    for (const unsafePath of [
      'C:\\Program Files\\Codex\\codex&safe.cmd',
      'C:\\Program Files\\Codex\\codex%PATH%.cmd',
      'C:\\Program Files\\Codex\\codex^safe.cmd',
      'C:\\Program Files\\Codex\\codex!safe.cmd',
      'C:\\Program Files\\Codex\\codex;safe.cmd',
      'C:\\Program Files\\Codex\\folder:codex.cmd',
      `C:\\${'x'.repeat(4090)}\\codex.cmd`,
    ]) {
      expect(codexSpawnSpec({
        platform: 'win32', systemRoot: 'C:\\Windows', shellPath: 'C:\\Windows\\System32\\cmd.exe',
        executablePath: unsafePath, isRegularFile: () => true,
      })).toBeUndefined();
    }

    expect(codexSpawnSpec({ platform: 'darwin', executablePath: `/${'x'.repeat(4096)}/codex`, isRegularFile: () => true })).toBeUndefined();
  });

  it('fails closed for an env command-name override instead of searching PATH', () => {
    const previousExecutable = process.env.CODEX_EXECUTABLE_PATH;
    try {
      process.env.CODEX_EXECUTABLE_PATH = 'codex.cmd';
      expect(codexSpawnSpec({
        platform: 'win32',
        systemRoot: 'C:\\Windows',
        shellPath: 'C:\\Windows\\System32\\cmd.exe',
        isRegularFile: () => true,
      })).toBeUndefined();
    } finally {
      if (previousExecutable === undefined) delete process.env.CODEX_EXECUTABLE_PATH;
      else process.env.CODEX_EXECUTABLE_PATH = previousExecutable;
    }
  });

  it('keeps disabled live mode from resolving or spawning Codex', async () => {
    const previous = process.env.CODEX_LIVE_ENABLED;
    const previousExecutable = process.env.CODEX_EXECUTABLE_PATH;
    try {
      process.env.CODEX_LIVE_ENABLED = 'false';
      delete process.env.CODEX_EXECUTABLE_PATH;
      await expect(readCodexLive()).resolves.toMatchObject({ connectorState: 'unavailable', error: 'Live Codex connector disabled' });
    } finally {
      if (previous === undefined) delete process.env.CODEX_LIVE_ENABLED; else process.env.CODEX_LIVE_ENABLED = previous;
      if (previousExecutable === undefined) delete process.env.CODEX_EXECUTABLE_PATH; else process.env.CODEX_EXECUTABLE_PATH = previousExecutable;
    }
  });

  it('fails closed when the default Codex executable is not configured', async () => {
    const previousExecutable = process.env.CODEX_EXECUTABLE_PATH;
    const previousShell = process.env.CODEX_SHELL_PATH;
    try {
      delete process.env.CODEX_EXECUTABLE_PATH;
      delete process.env.CODEX_SHELL_PATH;
      await expect(readCodexAppServer()).resolves.toMatchObject({ connectorState: 'unavailable', failureReason: 'transport' });
    } finally {
      if (previousExecutable === undefined) delete process.env.CODEX_EXECUTABLE_PATH; else process.env.CODEX_EXECUTABLE_PATH = previousExecutable;
      if (previousShell === undefined) delete process.env.CODEX_SHELL_PATH; else process.env.CODEX_SHELL_PATH = previousShell;
    }
  });

  it('accepts only the allowlisted rate-limit rejection after initialization', async () => {
    const providerUnavailable = await readCodexAppServer(() => transportFor(async method => {
      if (method === 'initialize') return {};
      throw new CodexRpcError(-32603, method);
    }).transport);
    expect(providerUnavailable.failureReason).toBe('provider_rejected');
    expect(providerUnavailable.windows).toEqual([]);

    const differentCode = await readCodexAppServer(() => transportFor(async method => {
      if (method === 'initialize') return {};
      throw new CodexRpcError(-32001, method);
    }).transport);
    expect(differentCode.failureReason).toBe('transport');

    const initializationFailure = await readCodexAppServer(() => transportFor(async () => {
      throw new CodexRpcError(-32603, 'initialize');
    }).transport);
    expect(initializationFailure.failureReason).toBe('transport');
  });

  it('marks a successful but unusable response as invalid instead of provider unavailable', async () => {
    const invalid = await readCodexAppServer(() => transportFor(async method => {
      if (method === 'initialize') return {};
      return { rateLimits: { primary: { usedPercent: 'unknown' } } };
    }).transport);
    expect(invalid.failureReason).toBe('invalid_response');

    const valid = await readCodexAppServer(() => transportFor(async method => {
      if (method === 'initialize') return {};
      return { rateLimits: { primary: { windowDurationMins: 300, usedPercent: 22 } } };
    }).transport);
    expect(valid.failureReason).toBeUndefined();
    expect(valid.windows).toEqual([{ minutes: 300, usedPercent: 22 }]);
    expect(valid.observedAt).toEqual(expect.any(String));
  });

  it('rejects pending requests and kills the child on a synchronous write failure', async () => {
    const child = new EventEmitter() as unknown as ChildProcess & {
      stdout: EventEmitter;
      stdin: { destroyed: boolean; write: () => boolean; end: () => void };
      killed: boolean;
      kill: () => boolean;
    };
    child.stdout = new EventEmitter();
    child.stdin = { destroyed: false, write: () => { throw new Error('write failed'); }, end: () => undefined };
    child.killed = false;
    child.kill = () => { child.killed = true; return true; };
    const transport = createCodexTransport(child);
    const request = transport({ method: 'initialize' });
    await expect(request).rejects.toThrow('Codex app-server process failed');
    expect(child.killed).toBe(true);
  });

  it('rejects pending requests and kills the child when the protocol times out', async () => {
    vi.useFakeTimers();
    try {
      const child = new EventEmitter() as unknown as ChildProcess & {
        stdout: EventEmitter;
        stdin: { destroyed: boolean; write: () => boolean; end: () => void };
        killed: boolean;
        kill: () => boolean;
      };
      child.stdout = new EventEmitter();
      child.stdin = { destroyed: false, write: () => true, end: () => undefined };
      child.killed = false;
      child.kill = () => { child.killed = true; return true; };
      const transport = createCodexTransport(child);
      const request = transport({ method: 'initialize' });
      const rejection = expect(request).rejects.toThrow('Codex app-server request timed out');
      await vi.advanceTimersByTimeAsync(8_000);
      await rejection;
      expect(child.killed).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });
});
