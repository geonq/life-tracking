import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { parseCodexFixture, parseOverview, fixtures, normalizeWindow, type UsageWindow } from '@iphone-life-os/contracts';
import { readCodexLive } from './codex-adapter.js';
import { UsageHistory } from './history.js';
import { projectUsage } from './projection.js';
import { constantTimeEqual, ingestClaudeStatusline, validClaudeContentType, MAX_BODY_BYTES } from './claude-ingest.js';
import { financeConnectors } from './finance-connectors.js';

const history = () => new UsageHistory(process.env.USAGE_STORE_PATH || 'usage-history.jsonl');
const json = (res: ServerResponse, status: number, value: unknown) => { res.statusCode = status; res.end(JSON.stringify(value)); };
const loopback = (req: IncomingMessage) => req.socket.remoteAddress === '127.0.0.1' || req.socket.remoteAddress === '::1';
async function body(req: IncomingMessage): Promise<string> {
  if (Number(req.headers['content-length'] || 0) > MAX_BODY_BYTES) throw new Error('body_too_large');
  let result = '';
  for await (const chunk of req) { result += String(chunk); if (Buffer.byteLength(result) > MAX_BODY_BYTES) throw new Error('body_too_large'); }
  return result;
}
async function ingest(req: IncomingMessage, res: ServerResponse) {
  if (!loopback(req)) return json(res, 403, { error: 'loopback_only' });
  const expected = process.env.CLAUDE_INGEST_SECRET || process.env.CLAUDE_STATUSLINE_TOKEN || '';
  const auth = req.headers.authorization || '';
  if (!expected || !auth.startsWith('Bearer ') || !constantTimeEqual(auth.slice(7), expected)) return json(res, 401, { error: 'unauthorized' });
  if (!validClaudeContentType(req.headers['content-type'])) return json(res, 415, { error: 'content_type' });
  let parsed: unknown;
  try { parsed = JSON.parse(await body(req)); } catch (error) { return json(res, error instanceof Error && error.message === 'body_too_large' ? 413 : 400, { error: error instanceof Error ? error.message : 'invalid_json' }); }
  const windows = ingestClaudeStatusline(parsed);
  const observedAt = new Date().toISOString();
  for (const window of windows) if (window.usedPercent !== undefined) await history().add({ provider: 'claude', window: window.window, durationMinutes: window.durationMinutes, usedPercent: window.usedPercent, resetAt: window.resetAt, observedAt });
  return json(res, 200, { windows, connector: 'healthy' });
}

export async function app(req: IncomingMessage, res: ServerResponse) {
  res.setHeader('content-type', 'application/json'); res.setHeader('cache-control', 'no-store');
  if (req.method === 'POST' && (req.url === '/api/usage/claude-ingest' || req.url === '/api/claude/statusline')) {
    if (process.env.CLAUDE_INGEST_ENABLED !== 'true' && process.env.CLAUDE_STATUSLINE_ENABLED !== 'true') return json(res, 404, { error: 'disabled' });
    return ingest(req, res);
  }
  if (req.method !== 'GET') return json(res, 405, { error: 'read_only_api' });
  if (req.url === '/health') return json(res, 200, { status: 'ok', demo: true, service: 'iphone-life-os-api' });
  if (req.url === '/api/overview') return json(res, 200, parseOverview(fixtures.overview));
  if (req.url === '/api/codex') return json(res, 200, parseCodexFixture(fixtures.codex));
  if (req.url === '/api/codex/live') return json(res, 200, await readCodexLive());
  if (req.url === '/api/finance/connectors') return json(res, 200, { connectors: financeConnectors });
  if (req.url === '/api/usage') {
    const now = new Date().toISOString(); const codex = await readCodexLive(); const store = history();
    const windows: UsageWindow[] = [];
    for (const item of codex.windows) {
      const window = normalizeWindow({ usedPercent: item.usedPercent, resetsAt: item.resetAt }, 'codex', item.minutes >= 10080 ? 'seven_day' : 'five_hour', 'codex-app-server', now);
      if (window.usedPercent !== undefined) await store.add({ provider: 'codex', window: window.window, durationMinutes: window.durationMinutes, usedPercent: window.usedPercent, resetAt: window.resetAt, observedAt: now });
    }
    const estimates = [];
    for (const provider of ['claude', 'codex'] as const) {
      for (const kind of ['five_hour', 'seven_day'] as const) {
        const samples = await store.list(provider, kind === 'five_hour' ? 300 : 10080);
        if (samples.length) {
          const latest = samples.at(-1)!;
          windows.push(normalizeWindow(latest, provider, kind, provider === 'claude' ? 'claude.ai-statusline' : 'codex-app-server', latest.observedAt));
          estimates.push(projectUsage(samples));
        }
      }
    }
    return json(res, 200, { generatedAt: now, windows, estimates, connectors: { codex: codex.connectorState, claude: process.env.CLAUDE_INGEST_ENABLED === 'true' || process.env.CLAUDE_STATUSLINE_ENABLED === 'true' ? 'healthy' : 'unavailable' } });
  }
  return json(res, 404, { error: 'not_found' });
}
export function createApiServer() { return createServer(app); }
if (process.env.NODE_ENV !== 'test') createApiServer().listen(Number(process.env.PORT || 8787), '127.0.0.1');
