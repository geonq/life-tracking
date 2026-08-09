import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { FinanceConnectorCatalog, FinanceSummary as FinanceSummarySchema, UnifiedUsage, parseCodexFixture, parseOverview, fixtures, normalizeWindow, type UsageWindow } from '@iphone-life-os/contracts';
import { readCodexLive } from './codex-adapter.js';
import { UsageHistory } from './history.js';
import { projectUsage } from './projection.js';
import { constantTimeEqual, ingestClaudeStatusline, validClaudeContentType, MAX_BODY_BYTES } from './claude-ingest.js';
import { financeConnectors } from './finance-connectors.js';

const history = () => new UsageHistory(process.env.USAGE_STORE_PATH || 'usage-history.jsonl');
const json = (res: ServerResponse, status: number, value: unknown) => { res.statusCode = status; res.end(JSON.stringify(value)); };
const unavailableFinanceSummary = () => {
  const generatedAt = new Date().toISOString();
  const metric = () => ({
    availability: 'unavailable' as const,
    provenance: {
      source: 'no-authorized-finance-source', observedAt: generatedAt,
      freshness: 'unknown' as const, quality: 'unavailable' as const,
      connectorState: 'unavailable' as const,
    },
  });
  return FinanceSummarySchema.parse({
    generatedAt, currency: 'EUR', monthlyIncome: metric(), fixedCosts: metric(),
    discretionaryBuffer: metric(), spent: metric(), savingsGoal: metric(), saved: metric(),
  });
};
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
  const observed = windows.filter(window => window.availability === 'observed' && window.usedPercent !== undefined);
  if (!observed.length) return json(res, 422, { error: 'usage_unavailable' });
  const connector = observed.some(window => window.provenance.connectorState === 'rate_limited') ? 'rate_limited' : 'healthy';
  const validated = UnifiedUsage.parse({ generatedAt: observedAt, windows: observed, estimates: [],
    connectors: { codex: 'unavailable', claude: connector } });
  for (const window of validated.windows) await history().add({ provider: 'claude', window: window.window,
    durationMinutes: window.durationMinutes, usedPercent: window.usedPercent!, resetAt: window.resetAt, observedAt });
  return json(res, 200, { windows: validated.windows, connector: validated.connectors.claude });
}

export async function app(req: IncomingMessage, res: ServerResponse, readLive: typeof readCodexLive = readCodexLive) {
  res.setHeader('content-type', 'application/json'); res.setHeader('cache-control', 'no-store');
  if (req.method === 'POST' && (req.url === '/api/usage/claude-ingest' || req.url === '/api/claude/statusline')) {
    if (process.env.CLAUDE_INGEST_ENABLED !== 'true' && process.env.CLAUDE_STATUSLINE_ENABLED !== 'true') return json(res, 404, { error: 'disabled' });
    return ingest(req, res);
  }
  if (req.method !== 'GET') return json(res, 405, { error: 'read_only_api' });
  if (req.url === '/health') return json(res, 200, { status: 'ok', demo: true, service: 'iphone-life-os-api' });
  if (req.url === '/api/overview') return json(res, 200, parseOverview(fixtures.overview));
  if (req.url === '/api/codex') return json(res, 200, parseCodexFixture(fixtures.codex));
  if (req.url === '/api/codex/live') return json(res, 200, await readLive());
  if (req.url === '/api/finance/connectors') return json(res, 200, FinanceConnectorCatalog.parse({ connectors: financeConnectors }));
  if (req.url === '/api/finance/summary') return json(res, 200, unavailableFinanceSummary());
  if (req.url === '/api/usage') {
    const now = new Date().toISOString(); const codex = await readLive(); const store = history();
    const windows: UsageWindow[] = [];
    for (const item of codex.windows) {
      const kind = item.minutes === 300 ? 'five_hour' : item.minutes === 10_080 ? 'seven_day' : undefined;
      if (!kind) continue;
      const window = normalizeWindow({ usedPercent: item.usedPercent, resetsAt: item.resetAt }, 'codex', kind, 'codex-app-server', now);
      if (window.usedPercent !== undefined) windows.push(window);
    }
    const estimates = [];
    for (const provider of ['claude', 'codex'] as const) {
      for (const kind of ['five_hour', 'seven_day'] as const) {
        const samples = await store.list(provider, kind === 'five_hour' ? 300 : 10080);
        if (samples.length) {
          const latest = samples.at(-1)!;
          if (!windows.some(window => window.provider === provider && window.window === kind)) {
            windows.push(normalizeWindow(latest, provider, kind, provider === 'claude' ? 'claude.ai-statusline' : 'codex-app-server', latest.observedAt));
          }
          estimates.push(projectUsage(samples));
        }
      }
    }
    const claudeEnabled = process.env.CLAUDE_INGEST_ENABLED === 'true' || process.env.CLAUDE_STATUSLINE_ENABLED === 'true';
    const claudeStates = windows
      .filter(window => window.provider === 'claude' && window.availability === 'observed')
      .map(window => window.provenance.connectorState);
    const claudeState = !claudeEnabled ? 'unavailable'
      : claudeStates.includes('rate_limited') ? 'rate_limited'
        : claudeStates.includes('healthy') ? 'healthy'
          : claudeStates.includes('refresh_due') ? 'refresh_due' : 'unavailable';
    return json(res, 200, UnifiedUsage.parse({
      generatedAt: now, windows, estimates,
      connectors: { codex: codex.connectorState, claude: claudeState },
    }));
  }
  return json(res, 404, { error: 'not_found' });
}
export function createApiServer(readLive: typeof readCodexLive = readCodexLive) { return createServer((req, res) => app(req, res, readLive)); }
if (process.env.NODE_ENV !== 'test') createApiServer().listen(Number(process.env.PORT || 8787), '127.0.0.1');
