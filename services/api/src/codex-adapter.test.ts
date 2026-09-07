import { EventEmitter } from 'node:events';
import type { ChildProcess } from 'node:child_process';
import { describe, expect, it, vi } from 'vitest';
import { CodexRpcError, createCodexTransport, readCodexAppServer, type Transport } from './codex-adapter.js';

function transportFor(handler: (method: string) => Promise<unknown>): { transport: Transport; close: ReturnType<typeof vi.fn> } {
  const close = vi.fn();
  const transport = (async (request: Record<string, unknown>) => handler(String(request.method))) as Transport;
  transport.close = close;
  return { transport, close };
}

describe('Codex app-server boundary', () => {
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
