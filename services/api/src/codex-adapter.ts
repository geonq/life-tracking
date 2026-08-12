import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { win32 } from 'node:path';

export type CodexWindow = { minutes: number; usedPercent: number; resetAt?: string };
export type CodexLiveResult = { connectorState: 'healthy' | 'unavailable' | 'rate_limited'; windows: CodexWindow[]; error?: string };
export type Transport = ((request: Record<string, unknown>) => Promise<unknown>) & { close?: () => void };

const supportedCodexMinutes = new Set([300, 10_080]);

const timeoutMs = 8_000;
const maxProtocolBufferBytes = 1_048_576;
const maxPendingRequests = 4;
const sensitive = /token|secret|password|credential|account|email|workspace|thread|prompt|path|home|user|credit/i;
const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/**
 * Parse the deliberately small collector wire payload. The collector sends
 * only this shape; rejecting every sibling is what prevents prompt/account/
 * path/token data from crossing into the API or history store.
 */
export function parseCodexIngestPayload(input: unknown): CodexWindow[] {
  if (!isObject(input) || Object.keys(input).length !== 1 || !Object.hasOwn(input, 'windows')
    || !Array.isArray(input.windows) || input.windows.length === 0 || input.windows.length > 2) {
    throw new Error('invalid_codex_payload');
  }
  const seen = new Set<number>();
  const windows: CodexWindow[] = [];
  for (const value of input.windows) {
    if (!isObject(value)) throw new Error('invalid_codex_payload');
    const keys = Object.keys(value);
    if (!(keys.length === 2 || keys.length === 3)
      || !Object.hasOwn(value, 'minutes') || !Object.hasOwn(value, 'usedPercent')
      || keys.some(key => key !== 'minutes' && key !== 'usedPercent' && key !== 'resetAt')) {
      throw new Error('invalid_codex_payload');
    }
    const minutes = value.minutes;
    const usedPercent = value.usedPercent;
    if (typeof minutes !== 'number' || !Number.isInteger(minutes) || !supportedCodexMinutes.has(minutes)
      || seen.has(minutes) || typeof usedPercent !== 'number' || !Number.isFinite(usedPercent)
      || usedPercent < 0 || usedPercent > 100) {
      throw new Error('invalid_codex_payload');
    }
    let resetAt: string | undefined;
    if (Object.hasOwn(value, 'resetAt')) {
      if (typeof value.resetAt !== 'string' || !Number.isFinite(Date.parse(value.resetAt))) {
        throw new Error('invalid_codex_payload');
      }
      resetAt = new Date(value.resetAt).toISOString();
    }
    seen.add(minutes);
    windows.push({ minutes, usedPercent, ...(resetAt ? { resetAt } : {}) });
  }
  return windows.sort((a, b) => a.minutes - b.minutes);
}

/** Map only the public RateLimitSnapshot fields. Unknown/sensitive fields are intentionally discarded. */
export function mapCodexResponse(rateLimits: unknown): CodexLiveResult {
  const envelope = isObject(rateLimits) && 'result' in rateLimits ? rateLimits.result : rateLimits;
  const root = isObject(envelope) && isObject(envelope.rateLimits) ? envelope.rateLimits
    : isObject(envelope) && isObject(envelope.rate_limits) ? envelope.rate_limits : envelope;
  const candidates = isObject(root) ? [root.primary, root.secondary, ...(Array.isArray(root.windows) ? root.windows : [])] : [];
  const windows: CodexWindow[] = [];
  const seenSupportedDurations = new Set<number>();
  for (const item of candidates) {
    if (!isObject(item)) continue;
    const rawMinutes = item.windowDurationMins ?? item.window_duration_mins ?? item.windowMinutes ?? item.window_minutes;
    const rawUsedPercent = item.usedPercent ?? item.used_percent;
    if (typeof rawMinutes !== 'number' || !Number.isFinite(rawMinutes)) continue;
    if (rawMinutes === 300 || rawMinutes === 10_080) {
      if (seenSupportedDurations.has(rawMinutes)) {
        return { connectorState: 'unavailable', windows: [], error: 'Codex returned duplicate rate-limit windows' };
      }
      seenSupportedDurations.add(rawMinutes);
    }
    if (
        typeof rawUsedPercent !== 'number' || !Number.isFinite(rawUsedPercent)) continue;
    const minutes = rawMinutes;
    const usedPercent = rawUsedPercent;
    const rawResetAt = item.resetsAt ?? item.resets_at;
    const resetDate = typeof rawResetAt === 'number' && Number.isFinite(rawResetAt)
      ? new Date(rawResetAt * 1000)
      : typeof rawResetAt === 'string' ? new Date(rawResetAt) : undefined;
    const resetAt = resetDate && Number.isFinite(resetDate.getTime()) ? resetDate.toISOString() : undefined;
    if ((minutes !== 300 && minutes !== 10_080) || !Number.isFinite(usedPercent) || usedPercent < 0 || usedPercent > 100) continue;
    windows.push({ minutes, usedPercent, ...(resetAt ? { resetAt } : {}) });
  }
  windows.sort((a, b) => a.minutes - b.minutes);
  return windows.length ? { connectorState: windows.some(w => w.usedPercent >= 100) ? 'rate_limited' : 'healthy', windows } : { connectorState: 'unavailable', windows: [], error: 'Codex returned no valid rate-limit windows' };
}

export function codexSpawnSpec(platform = process.platform, commandShell = process.env.ComSpec || 'cmd.exe'): { command: string; args: string[] } {
  return platform === 'win32'
    ? { command: commandShell, args: ['/d', '/s', '/c', 'codex.cmd', 'app-server'] }
    : { command: 'codex', args: ['app-server'] };
}

/** Never let a writable collector working directory shadow `codex.cmd`. */
export function codexWorkingDirectory(platform = process.platform, commandShell = process.env.ComSpec || 'cmd.exe'): string {
  if (platform !== 'win32') return '/';
  // Keep the parameter in the signature for deterministic platform tests, but
  // never derive cwd from ComSpec: an overridden shell path may be writable.
  void commandShell;
  const systemRoot = typeof process.env.SystemRoot === 'string' && /^[A-Za-z]:\\Windows$/i.test(process.env.SystemRoot)
    ? process.env.SystemRoot : 'C:\\Windows';
  return win32.join(systemRoot, 'System32');
}

function spawnCodex(): ChildProcess {
  const spec = codexSpawnSpec();
  return spawn(spec.command, spec.args, {
    cwd: codexWorkingDirectory(), stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true,
  });
}

export function createCodexTransport(child: ChildProcess = spawnCodex()): Transport {
  let nextId = 1; let buffer = ''; let closed = false;
  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  const finish = (error?: Error) => { if (closed) return; closed = true; for (const p of [...pending.values()]) { clearTimeout(p.timer); p.reject(error ?? new Error('Codex app-server closed')); } pending.clear(); child.stdout?.removeAllListeners('data'); child.removeAllListeners('error'); child.removeAllListeners('exit'); if (child.stdin && !child.stdin.destroyed) child.stdin.end(); if (!child.killed) child.kill(); };
  child.stdout?.on('data', chunk => { buffer += String(chunk); if (Buffer.byteLength(buffer, 'utf8') > maxProtocolBufferBytes) { finish(new Error('Codex app-server protocol frame exceeded size limit')); return; } const lines = buffer.split('\n'); buffer = lines.pop() ?? ''; for (const line of lines) { if (!line.trim()) continue; try { const msg = JSON.parse(line); if (!isObject(msg) || typeof msg.id !== 'number') continue; const p = pending.get(msg.id); if (!p) continue; pending.delete(msg.id); clearTimeout(p.timer); if (isObject(msg.error)) p.reject(new Error('Codex app-server JSON-RPC error')); else if (!('result' in msg)) p.reject(new Error('Malformed Codex app-server response')); else p.resolve(msg.result); } catch { /* malformed protocol is handled by request timeout/failure */ } } });
  child.once('error', () => finish(new Error('Codex app-server process failed')));
  child.once('exit', code => { if (code !== 0) finish(new Error('Codex app-server process failed')); });
  const request = ((payload: Record<string, unknown>) => new Promise((resolve, reject) => { if (closed || !child.stdin || child.stdin.destroyed) return reject(new Error('Codex app-server unavailable')); if (pending.size >= maxPendingRequests) return reject(new Error('Codex app-server request limit reached')); const id = nextId++; const timer = setTimeout(() => { pending.delete(id); finish(new Error('Codex app-server request timed out')); }, timeoutMs); pending.set(id, { resolve, reject, timer }); try { child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, ...payload }) + '\n'); } catch { pending.delete(id); clearTimeout(timer); finish(new Error('Codex app-server process failed')); } })) as Transport;
  request.close = () => finish(new Error('Codex transport closed'));
  return request;
}

export async function readCodexAppServer(transportFactory: () => Transport = () => createCodexTransport()): Promise<CodexLiveResult> {
  let transport: Transport | undefined; try { transport = transportFactory(); await transport({ method: 'initialize', params: { clientInfo: { name: 'iphone-life-os', version: '0.1.0' } } }); const limits = await transport({ method: 'account/rateLimits/read', params: {} }); return mapCodexResponse(limits); } catch { return { connectorState: 'unavailable', windows: [], error: 'Codex connector unavailable' }; } finally { transport?.close?.(); }
}

export async function readCodexLive(transportFactory: () => Transport = () => createCodexTransport()): Promise<CodexLiveResult> {
  if (process.env.CODEX_LIVE_ENABLED !== 'true') return { connectorState: 'unavailable', windows: [], error: 'Live Codex connector disabled' };
  return readCodexAppServer(transportFactory);
}

export const containsSensitiveKeys = (value: unknown): boolean => JSON.stringify(value, (key, v) => sensitive.test(key) ? '[REDACTED]' : v).includes('[REDACTED]');
