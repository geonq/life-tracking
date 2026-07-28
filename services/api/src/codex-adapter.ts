import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';

export type CodexWindow = { minutes: number; usedPercent: number; resetAt?: string };
export type CodexLiveResult = { connectorState: 'healthy' | 'unavailable' | 'rate_limited'; windows: CodexWindow[]; error?: string };
export type Transport = ((request: Record<string, unknown>) => Promise<unknown>) & { close?: () => void };

const timeoutMs = 8_000;
const sensitive = /token|secret|password|credential|account|email|workspace|thread|prompt|path|home|user|credit/i;
const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/** Map only the public RateLimitSnapshot fields. Unknown/sensitive fields are intentionally discarded. */
export function mapCodexResponse(rateLimits: unknown): CodexLiveResult {
  const root = isObject(rateLimits) && 'result' in rateLimits ? rateLimits.result : rateLimits;
  const candidates = isObject(root) ? [root.primary, root.secondary, ...(Array.isArray(root.windows) ? root.windows : [])] : [];
  const windows: CodexWindow[] = [];
  for (const item of candidates) {
    if (!isObject(item)) continue;
    const minutes = Number(item.windowDurationMins ?? item.window_duration_mins ?? item.windowMinutes ?? item.window_minutes);
    const usedPercent = Number(item.usedPercent ?? item.used_percent);
    const resetAt = item.resetsAt ?? item.resets_at;
    if (!Number.isFinite(minutes) || minutes <= 0 || !Number.isFinite(usedPercent) || usedPercent < 0 || usedPercent > 100) continue;
    if (windows.some(w => w.minutes === minutes)) continue;
    windows.push({ minutes, usedPercent, ...(typeof resetAt === 'string' && Number.isFinite(Date.parse(resetAt)) ? { resetAt } : {}) });
  }
  windows.sort((a, b) => a.minutes - b.minutes);
  return windows.length ? { connectorState: windows.some(w => w.usedPercent >= 100) ? 'rate_limited' : 'healthy', windows } : { connectorState: 'unavailable', windows: [], error: 'Codex returned no valid rate-limit windows' };
}

export function createCodexTransport(child: ChildProcess = spawn('codex', ['app-server'], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true })): Transport {
  let nextId = 1; let buffer = ''; let closed = false;
  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  const finish = (error?: Error) => { if (closed) return; closed = true; for (const p of [...pending.values()]) { clearTimeout(p.timer); p.reject(error ?? new Error('Codex app-server closed')); } pending.clear(); child.stdout?.removeAllListeners('data'); child.removeAllListeners('error'); child.removeAllListeners('exit'); if (child.stdin && !child.stdin.destroyed) child.stdin.end(); if (!child.killed) child.kill(); };
  child.stdout?.on('data', chunk => { buffer += String(chunk); const lines = buffer.split('\n'); buffer = lines.pop() ?? ''; for (const line of lines) { if (!line.trim()) continue; try { const msg = JSON.parse(line); if (!isObject(msg) || typeof msg.id !== 'number') continue; const p = pending.get(msg.id); if (!p) continue; pending.delete(msg.id); clearTimeout(p.timer); if (isObject(msg.error)) p.reject(new Error('Codex app-server JSON-RPC error')); else if (!('result' in msg)) p.reject(new Error('Malformed Codex app-server response')); else p.resolve(msg.result); } catch { /* malformed protocol is handled by request timeout/failure */ } } });
  child.once('error', () => finish(new Error('Codex app-server process failed')));
  child.once('exit', code => { if (code !== 0) finish(new Error('Codex app-server process failed')); });
  const request = ((payload: Record<string, unknown>) => new Promise((resolve, reject) => { if (closed || !child.stdin || child.stdin.destroyed) return reject(new Error('Codex app-server unavailable')); const id = nextId++; const timer = setTimeout(() => { pending.delete(id); finish(new Error('Codex app-server request timed out')); }, timeoutMs); pending.set(id, { resolve, reject, timer }); try { child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, ...payload }) + '\n'); } catch { pending.delete(id); clearTimeout(timer); finish(new Error('Codex app-server process failed')); } })) as Transport;
  request.close = () => finish(new Error('Codex transport closed'));
  return request;
}

export async function readCodexLive(transportFactory: () => Transport = () => createCodexTransport()): Promise<CodexLiveResult> {
  if (process.env.CODEX_LIVE_ENABLED !== 'true') return { connectorState: 'unavailable', windows: [], error: 'Live Codex connector disabled' };
  let transport: Transport | undefined; try { transport = transportFactory(); await transport({ method: 'initialize', params: { clientInfo: { name: 'iphone-life-os', version: '0.1.0' } } }); const limits = await transport({ method: 'account/rateLimits/read', params: {} }); return mapCodexResponse(limits); } catch { return { connectorState: 'unavailable', windows: [], error: 'Codex connector unavailable' }; } finally { transport?.close?.(); }
}

export const containsSensitiveKeys = (value: unknown): boolean => JSON.stringify(value, (key, v) => sensitive.test(key) ? '[REDACTED]' : v).includes('[REDACTED]');
