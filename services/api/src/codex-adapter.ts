import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { lstatSync } from 'node:fs';
import { posix, win32 } from 'node:path';
import { parseStrictJSON } from './json-boundary.js';

export type CodexWindow = { minutes: number; usedPercent: number; resetAt?: string };
export type CodexFailureReason = 'provider_rejected' | 'transport' | 'invalid_response';
export type CodexLiveResult = {
  connectorState: 'healthy' | 'unavailable' | 'rate_limited';
  windows: CodexWindow[];
  observedAt?: string;
  error?: string;
  // Internal-only classification used by the scheduled collector. It is
  // deliberately absent from the public usage payload.
  failureReason?: CodexFailureReason;
};
export type Transport = ((request: Record<string, unknown>) => Promise<unknown>) & { close?: () => void };

export class CodexRpcError extends Error {
  constructor(readonly code: number | undefined, readonly method: string) {
    super('Codex app-server request failed');
    this.name = 'CodexRpcError';
  }
}

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
export function parseCodexIngestEnvelope(input: unknown): { windows: CodexWindow[]; observedAt?: string } {
  if (!isObject(input) || (Object.keys(input).length !== 1 && Object.keys(input).length !== 2) || !Object.hasOwn(input, 'windows')
    || (Object.keys(input).length === 2 && !Object.hasOwn(input, 'observedAt'))
    || !Array.isArray(input.windows) || input.windows.length === 0 || input.windows.length > 2) {
    throw new Error('invalid_codex_payload');
  }
  let observedAt: string | undefined;
  if (Object.hasOwn(input, 'observedAt')) {
    if (typeof input.observedAt !== 'string' || input.observedAt.length > 64 || !Number.isFinite(Date.parse(input.observedAt))
      || Date.parse(input.observedAt) > Date.now() + 5_000) throw new Error('invalid_codex_payload');
    observedAt = new Date(input.observedAt).toISOString();
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
  return { windows: windows.sort((a, b) => a.minutes - b.minutes), ...(observedAt ? { observedAt } : {}) };
}

export function parseCodexIngestPayload(input: unknown): CodexWindow[] {
  return parseCodexIngestEnvelope(input).windows;
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

export type CodexSpawnSpec = { command: string; args: string[] };
export type CodexSpawnOptions = {
  platform?: string;
  executablePath?: string;
  shellPath?: string;
  systemRoot?: string;
  isRegularFile?: (path: string) => boolean;
};

const defaultWindowsRoot = 'C:\\Windows';
const maxExecutablePathLength = 4096;
const regularFile = (path: string): boolean => {
  try {
    const entry = lstatSync(path);
    return entry.isFile() && !entry.isSymbolicLink();
  } catch {
    return false;
  }
};

function windowsSystemRoot(value: string | undefined): string | undefined {
  if (value === undefined) return defaultWindowsRoot;
  if (!/^[A-Za-z]:[\\/]Windows$/i.test(value)) return undefined;
  return win32.normalize(value);
}

function approvedWindowsPath(value: string): boolean {
  return /^[A-Za-z]:[\\/]/.test(value)
    && win32.isAbsolute(value)
    && value.length <= maxExecutablePathLength
    && !/[\u0000-\u001f\u007f"<>|?*%&^!;:]/.test(value.slice(2));
}

function approvedPosixPath(value: string): boolean {
  return posix.isAbsolute(value)
    && value.length <= maxExecutablePathLength
    && !/[\u0000-\u001f\u007f]/.test(value);
}

/**
 * Resolve the only process paths the adapter may launch. The executable is
 * deliberately explicit; no PATH lookup is performed. Windows uses the
 * system cmd.exe only, and both paths must be existing non-symlink files.
 */
export function codexSpawnSpec(options: CodexSpawnOptions = {}): CodexSpawnSpec | undefined {
  const platform = options.platform ?? process.platform;
  const isRegularFile = options.isRegularFile ?? regularFile;
  const executablePath = options.executablePath ?? process.env.CODEX_EXECUTABLE_PATH;
  if (!executablePath) return undefined;

  if (platform === 'win32') {
    const systemRoot = windowsSystemRoot(options.systemRoot ?? process.env.SystemRoot);
    if (!systemRoot) return undefined;
    const expectedShell = win32.join(systemRoot, 'System32', 'cmd.exe');
    const shellPath = options.shellPath ?? process.env.CODEX_SHELL_PATH ?? process.env.ComSpec ?? expectedShell;
    if (!approvedWindowsPath(shellPath) || win32.normalize(shellPath).toLowerCase() !== expectedShell.toLowerCase()) return undefined;
    if (!approvedWindowsPath(executablePath)) return undefined;
    const normalizedExecutable = win32.normalize(executablePath);
    const executableName = win32.basename(normalizedExecutable).toLowerCase();
    if (executableName !== 'codex.cmd' && executableName !== 'codex.exe') return undefined;
    const normalizedShell = win32.normalize(shellPath);
    if (!isRegularFile(normalizedShell) || !isRegularFile(normalizedExecutable)) return undefined;
    return {
      command: normalizedShell,
      // Keep the command passed to /c as one argument and quote the explicit
      // path so spaces in the approved installation directory stay inert.
      args: ['/d', '/s', '/c', `"${normalizedExecutable}" app-server`],
    };
  }

  if (!approvedPosixPath(executablePath)) return undefined;
  const normalizedExecutable = posix.normalize(executablePath);
  if (posix.basename(normalizedExecutable) !== 'codex' || !isRegularFile(normalizedExecutable)) return undefined;
  return { command: normalizedExecutable, args: ['app-server'] };
}

/** Never let a writable collector working directory shadow `codex.cmd`. */
export function codexWorkingDirectory(platform = process.platform, systemRootOverride = process.env.SystemRoot): string {
  if (platform !== 'win32') return '/';
  const systemRoot = windowsSystemRoot(systemRootOverride) ?? defaultWindowsRoot;
  return win32.join(systemRoot, 'System32');
}

function spawnCodex(): ChildProcess {
  const systemRoot = process.env.SystemRoot;
  const spec = codexSpawnSpec({ platform: process.platform, systemRoot });
  if (!spec) throw new Error('Codex app-server unavailable');
  return spawn(spec.command, spec.args, {
    cwd: codexWorkingDirectory(process.platform, systemRoot), stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true,
  });
}

export function createCodexTransport(child: ChildProcess = spawnCodex()): Transport {
  let nextId = 1; let buffer = ''; let closed = false;
  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout>; method: string }>();
  const finish = (error?: Error) => { if (closed) return; closed = true; for (const p of [...pending.values()]) { clearTimeout(p.timer); p.reject(error ?? new Error('Codex app-server closed')); } pending.clear(); child.stdout?.removeAllListeners('data'); child.removeAllListeners('error'); child.removeAllListeners('exit'); if (child.stdin && !child.stdin.destroyed) child.stdin.end(); if (!child.killed) child.kill(); };
  child.stdout?.on('data', chunk => { buffer += String(chunk); if (Buffer.byteLength(buffer, 'utf8') > maxProtocolBufferBytes) { finish(new Error('Codex app-server protocol frame exceeded size limit')); return; } const lines = buffer.split('\n'); buffer = lines.pop() ?? ''; for (const line of lines) { if (!line.trim()) continue; try { const msg = parseStrictJSON(line); if (!isObject(msg) || typeof msg.id !== 'number') continue; const p = pending.get(msg.id); if (!p) continue; pending.delete(msg.id); clearTimeout(p.timer); if (isObject(msg.error)) p.reject(new CodexRpcError(typeof msg.error.code === 'number' ? msg.error.code : undefined, p.method)); else if (!('result' in msg)) p.reject(new Error('Malformed Codex app-server response')); else p.resolve(msg.result); } catch { /* malformed protocol is handled by request timeout/failure */ } } });
  child.once('error', () => finish(new Error('Codex app-server process failed')));
  child.once('exit', code => { if (code !== 0) finish(new Error('Codex app-server process failed')); });
  const request = ((payload: Record<string, unknown>) => new Promise((resolve, reject) => { if (closed || !child.stdin || child.stdin.destroyed) return reject(new Error('Codex app-server unavailable')); if (pending.size >= maxPendingRequests) return reject(new Error('Codex app-server request limit reached')); const id = nextId++; const method = typeof payload.method === 'string' ? payload.method : 'unknown'; const timer = setTimeout(() => { finish(new Error('Codex app-server request timed out')); }, timeoutMs); pending.set(id, { resolve, reject, timer, method }); try { child.stdin.write(JSON.stringify({ ...payload, jsonrpc: '2.0', id }) + '\n'); } catch { finish(new Error('Codex app-server process failed')); } })) as Transport;
  request.close = () => finish(new Error('Codex transport closed'));
  return request;
}

export async function readCodexAppServer(transportFactory: () => Transport = () => createCodexTransport()): Promise<CodexLiveResult> {
  let transport: Transport | undefined;
  try {
    transport = transportFactory();
    try {
      await transport({ method: 'initialize', params: { clientInfo: { name: 'iphone-life-os', version: '0.1.0' } } });
    } catch {
      return { connectorState: 'unavailable', windows: [], error: 'Codex connector unavailable', failureReason: 'transport' };
    }
    let limits: unknown;
    try {
      limits = await transport({ method: 'account/rateLimits/read', params: {} });
    } catch (error) {
      // This is the one provider-level failure that may be accepted during
      // installation: the app-server is reachable and initialized, but this
      // optional account capability is unavailable. Keep the method and code
      // allowlist narrow so spawn, auth, protocol, and timeout failures still
      // fail closed.
      if (error instanceof CodexRpcError && error.method === 'account/rateLimits/read' && error.code === -32603) {
        return { connectorState: 'unavailable', windows: [], error: 'Codex rate-limit provider unavailable', failureReason: 'provider_rejected' };
      }
      return { connectorState: 'unavailable', windows: [], error: 'Codex connector unavailable', failureReason: 'transport' };
    }
    const result = mapCodexResponse(limits);
    return result.windows.length
      ? { ...result, observedAt: new Date().toISOString() }
      : { ...result, failureReason: 'invalid_response' };
  } catch {
    return { connectorState: 'unavailable', windows: [], error: 'Codex connector unavailable', failureReason: 'transport' };
  } finally { transport?.close?.(); }
}

export async function readCodexLive(transportFactory: () => Transport = () => createCodexTransport()): Promise<CodexLiveResult> {
  if (process.env.CODEX_LIVE_ENABLED !== 'true') return { connectorState: 'unavailable', windows: [], error: 'Live Codex connector disabled' };
  return readCodexAppServer(transportFactory);
}

export const containsSensitiveKeys = (value: unknown): boolean => JSON.stringify(value, (key, v) => sensitive.test(key) ? '[REDACTED]' : v).includes('[REDACTED]');
