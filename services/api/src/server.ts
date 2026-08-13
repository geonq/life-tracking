import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { constants as fsConstants } from 'node:fs';
import { access, lstat, open } from 'node:fs/promises';
import { dirname, isAbsolute, resolve } from 'node:path';
import { ClipperSnapshot, FinanceConnectorCatalog, FinanceSummary as FinanceSummarySchema, UnifiedUsage, parseCodexFixture, parseOverview, fixtures, normalizeWindow, type UsageWindow, unavailableClipperSnapshot } from '@iphone-life-os/contracts';
import { parseCodexIngestPayload, readCodexLive } from './codex-adapter.js';
import { UsageHistory } from './history.js';
import { projectUsage } from './projection.js';
import { constantTimeEqual, ingestClaudeStatusline, validClaudeContentType, MAX_BODY_BYTES } from './claude-ingest.js';
import { financeConnectors } from './finance-connectors.js';
import { readIngestSecretFile } from './ingest-secret.js';
import { createConfiguredOpenFoodFactsClient, type OpenFoodFactsClient } from './open-food-facts.js';
import { CALENDAR_MAX_BYTES, CalendarStore, CalendarStoreError, type CalendarResource, type CalendarStoreErrorCode } from './calendar-store.js';

function usageStorePath(): string | undefined {
  const configured = process.env.USAGE_STORE_PATH;
  if (configured !== undefined && (!configured || configured.includes('\0') || !isAbsolute(configured))) return undefined;
  return resolve(configured ?? 'usage-history.jsonl');
}
const history = () => new UsageHistory(usageStorePath() ?? resolve('usage-history.jsonl'));
const defaultCalendarStore = new CalendarStore();
const json = (res: ServerResponse, status: number, value: unknown) => { res.statusCode = status; res.end(JSON.stringify(value)); };
const calendarResource = (res: ServerResponse, status: number, resource: CalendarResource, replay = false) => {
  res.statusCode = status;
  res.setHeader('etag', resource.etag);
  if (replay) res.setHeader('x-lifeos-idempotent-replay', 'true');
  res.end(resource.body);
};
async function readClaudeSecretFile(pathValue: string): Promise<string | undefined> {
  return readIngestSecretFile(pathValue);
}
async function claudeIngestSecret(): Promise<string | undefined> {
  const configuredFile = process.env.CLAUDE_INGEST_SECRET_FILE;
  if (configuredFile === undefined) return undefined;
  return readClaudeSecretFile(configuredFile);
}
const claudeIngestEnabled = () => process.env.CLAUDE_INGEST_ENABLED === 'true' || process.env.CLAUDE_STATUSLINE_ENABLED === 'true';
const codexIngestEnabled = () => process.env.CODEX_INGEST_ENABLED === 'true';
const codexIngestSecret = () => readIngestSecretFile(process.env.CODEX_INGEST_SECRET_FILE);

/** Validate the store's parent/file identity and contents without mutating it. */
async function validateUsageStore(): Promise<boolean> {
  const filePath = usageStorePath();
  if (!filePath) return false;
  const parentPath = dirname(filePath);
  try {
    const parent = await lstat(parentPath);
    if (!parent.isDirectory() || parent.isSymbolicLink()
      || (process.platform !== 'win32' && (parent.mode & 0o022) !== 0)) return false;
    await access(parentPath, fsConstants.R_OK | fsConstants.W_OK | fsConstants.X_OK);
    let fileExists = false;
    try {
      const file = await lstat(filePath);
      if (!file.isFile() || file.isSymbolicLink()
        || (process.platform !== 'win32' && (file.mode & 0o077) !== 0)) return false;
      await access(filePath, fsConstants.R_OK | fsConstants.W_OK);
      let descriptor: Awaited<ReturnType<typeof open>> | undefined;
      try {
        descriptor = await open(filePath, fsConstants.O_RDWR | (fsConstants.O_NOFOLLOW ?? 0));
        const opened = await descriptor.stat();
        if (!opened.isFile() || opened.isSymbolicLink()
          || opened.dev !== file.dev || opened.ino !== file.ino || opened.size !== file.size) return false;
      } finally {
        if (descriptor) await descriptor.close().catch(() => undefined);
      }
      fileExists = true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') return false;
    }
    // A missing file is valid when its safe parent is writable; an existing
    // file must also parse as bounded UsageHistory before readiness is true.
    return fileExists ? history().ready() : true;
  } catch {
    return false;
  }
}

/** Startup gate: enabled ingestion must have a valid file-only secret before binding. */
export async function validateStartupConfiguration(): Promise<boolean> {
  if (claudeIngestEnabled() && (await claudeIngestSecret()) === undefined) return false;
  if (codexIngestEnabled() && (await codexIngestSecret()) === undefined) return false;
  return validateUsageStore();
}
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
async function body(req: IncomingMessage, maximumBytes = MAX_BODY_BYTES): Promise<string> {
  const declared = req.headers['content-length'];
  if (declared !== undefined) {
    const value = typeof declared === 'string' ? Number(declared) : Number.NaN;
    if (!Number.isSafeInteger(value) || value < 0 || value > maximumBytes) throw new Error('body_too_large');
  }
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
    total += bytes.byteLength;
    if (total > maximumBytes) throw new Error('body_too_large');
    chunks.push(bytes);
  }
  return Buffer.concat(chunks).toString('utf8');
}
async function ingest(req: IncomingMessage, res: ServerResponse) {
  if (!loopback(req)) return json(res, 403, { error: 'loopback_only' });
  const expected = await claudeIngestSecret();
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
    connectors: {
      codex: 'unavailable', claude: connector,
      glm: 'unavailable', deepseek: 'unavailable', google_ai_studio: 'unavailable',
    } });
  try {
    await history().addMany(validated.windows.map(window => ({ provider: 'claude', window: window.window,
      durationMinutes: window.durationMinutes, usedPercent: window.usedPercent!, resetAt: window.resetAt, observedAt })));
  } catch {
    return json(res, 503, { error: 'usage_store_unavailable' });
  }
  return json(res, 200, { windows: validated.windows, connector: validated.connectors.claude });
}

async function ingestCodex(req: IncomingMessage, res: ServerResponse) {
  if (!loopback(req)) return json(res, 403, { error: 'forbidden' });
  const expected = await codexIngestSecret();
  const auth = req.headers.authorization || '';
  if (!expected || !auth.startsWith('Bearer ') || !constantTimeEqual(auth.slice(7), expected)) {
    return json(res, 401, { error: 'unauthorized' });
  }
  if (req.headers['content-type'] !== 'application/json') return json(res, 415, { error: 'invalid_request' });
  let parsed: unknown;
  try {
    parsed = JSON.parse(await body(req));
  } catch (error) {
    return json(res, error instanceof Error && error.message === 'body_too_large' ? 413 : 400, { error: 'invalid_request' });
  }
  let windows;
  try {
    windows = parseCodexIngestPayload(parsed);
  } catch {
    return json(res, 400, { error: 'invalid_request' });
  }
  const observedAt = new Date().toISOString();
  try {
    await history().addMany(windows.map(window => ({
      provider: 'codex' as const,
      window: window.minutes === 300 ? 'five_hour' as const : 'seven_day' as const,
      durationMinutes: window.minutes,
      usedPercent: window.usedPercent,
      ...(window.resetAt ? { resetAt: window.resetAt } : {}),
      observedAt,
    })));
  } catch {
    return json(res, 503, { error: 'unavailable' });
  }
  return json(res, 200, { ok: true });
}

function barcodeInput(url: string): string | undefined {
  const prefixes = ['/api/nutrition/barcode/', '/nutrition/barcode/'];
  const prefix = prefixes.find(value => url.startsWith(value));
  if (!prefix) return undefined;
  const encoded = url.slice(prefix.length);
  if (!encoded || encoded.includes('/') || encoded.includes('?') || encoded.includes('#')) throw new Error('invalid_barcode');
  try { return decodeURIComponent(encoded); } catch { throw new Error('invalid_barcode'); }
}

async function lookupBarcode(req: IncomingMessage, res: ServerResponse, client: OpenFoodFactsClient) {
  let input: string;
  try {
    input = barcodeInput(req.url ?? '') ?? (() => { throw new Error('invalid_barcode'); })();
  } catch {
    return json(res, 400, { error: 'invalid_barcode' });
  }
  try {
    return json(res, 200, await client.lookup(input));
  } catch {
    return json(res, 400, { error: 'invalid_barcode' });
  }
}

function singleHeader(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name.toLowerCase()];
  return typeof value === 'string' ? value : undefined;
}

function calendarError(res: ServerResponse, store: CalendarStore, error: unknown) {
  const code: CalendarStoreErrorCode = error instanceof CalendarStoreError
    ? error.code
    : error instanceof Error && error.message === 'body_too_large' ? 'body_too_large' : 'invalid_resource';
  const status: Record<string, number> = {
    body_too_large: 413,
    invalid_json: 400,
    invalid_resource: 400,
    missing_if_match: 428,
    invalid_if_match: 400,
    stale_revision: 412,
    missing_idempotency_key: 400,
    invalid_idempotency_key: 400,
    idempotency_key_reuse: 409,
    idempotency_store_full: 503,
  };
  // Revision/identity failures return the authoritative bytes and ETag. This
  // lets the client merge truth without ever treating an error as permission
  // to blindly overwrite the current resource.
  if (code === 'missing_if_match' || code === 'invalid_if_match' || code === 'stale_revision'
      || code === 'missing_idempotency_key' || code === 'invalid_idempotency_key'
      || code === 'idempotency_key_reuse' || code === 'idempotency_store_full') {
    return calendarResource(res, status[code] ?? 400, store.get());
  }
  return json(res, status[code] ?? 400, { error: code });
}

async function calendar(req: IncomingMessage, res: ServerResponse, store: CalendarStore) {
  if (req.method === 'GET') return calendarResource(res, 200, store.get());
  if (req.method !== 'PUT') return json(res, 405, { error: 'calendar_method_not_allowed' });
  if (singleHeader(req, 'content-type') !== 'application/json') return json(res, 415, { error: 'content_type' });

  let payload: string;
  try {
    payload = await body(req, CALENDAR_MAX_BYTES);
  } catch (error) {
    return calendarError(res, store, error);
  }
  try {
    const outcome = store.put(singleHeader(req, 'if-match'), singleHeader(req, 'idempotency-key'), payload);
    return calendarResource(res, 200, outcome.resource, outcome.kind === 'replay');
  } catch (error) {
    return calendarError(res, store, error);
  }
}

export async function app(
  req: IncomingMessage,
  res: ServerResponse,
  readLive: typeof readCodexLive = readCodexLive,
  barcodeClient?: OpenFoodFactsClient,
  calendarStore?: CalendarStore,
) {
  const configuredBarcodeClient = barcodeClient ?? createConfiguredOpenFoodFactsClient();
  const configuredCalendarStore = calendarStore ?? defaultCalendarStore;
  res.setHeader('content-type', 'application/json'); res.setHeader('cache-control', 'no-store');
  if (req.method === 'POST' && (req.url === '/api/usage/claude-ingest' || req.url === '/api/claude/statusline')) {
    if (process.env.CLAUDE_INGEST_ENABLED !== 'true' && process.env.CLAUDE_STATUSLINE_ENABLED !== 'true') return json(res, 404, { error: 'disabled' });
    return ingest(req, res);
  }
  if (req.method === 'POST' && req.url === '/api/usage/codex-ingest') {
    if (!codexIngestEnabled()) return json(res, 404, { error: 'disabled' });
    return ingestCodex(req, res);
  }
  if (req.url === '/api/calendar' || req.url === '/calendar') {
    return calendar(req, res, configuredCalendarStore);
  }
  if (req.method !== 'GET') return json(res, 405, { error: 'read_only_api' });
  if (req.url?.startsWith('/api/nutrition/barcode/') || req.url?.startsWith('/nutrition/barcode/')) {
    return lookupBarcode(req, res, configuredBarcodeClient);
  }
  if (req.url === '/health') return json(res, 200, { status: 'ok', demo: true, service: 'iphone-life-os-api' });
  if (req.url === '/api/overview') return json(res, 200, parseOverview(fixtures.overview));
  if (req.url === '/api/codex') return json(res, 200, parseCodexFixture(fixtures.codex));
  if (req.url === '/api/codex/live') return json(res, 200, await readLive());
  if (req.url === '/api/finance/connectors') return json(res, 200, FinanceConnectorCatalog.parse({ connectors: financeConnectors }));
  if (req.url === '/api/finance/summary') return json(res, 200, unavailableFinanceSummary());
  if (req.url === '/api/clipper/summary') return json(res, 200, ClipperSnapshot.parse(unavailableClipperSnapshot()));
  if (req.url === '/api/usage') {
    const now = new Date().toISOString();
    const codex = process.env.CODEX_LIVE_ENABLED === 'true'
      ? await readLive()
      : { connectorState: 'unavailable' as const, windows: [] };
    const store = history();
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
    const claudeEnabled = claudeIngestEnabled();
    const claudeStates = windows
      .filter(window => window.provider === 'claude' && window.availability === 'observed')
      .map(window => window.provenance.connectorState);
    const claudeState = !claudeEnabled ? 'unavailable'
      : claudeStates.includes('rate_limited') ? 'rate_limited'
        : claudeStates.includes('healthy') ? 'healthy'
          : claudeStates.includes('refresh_due') ? 'refresh_due' : 'unavailable';
    const codexEnabled = process.env.CODEX_LIVE_ENABLED === 'true';
    const codexStates = windows
      .filter(window => window.provider === 'codex' && window.availability === 'observed')
      .map(window => window.provenance.connectorState);
    // When the direct app-server connector is intentionally disabled, the
    // collector's history remains an honest source. Its freshness determines
    // healthy vs refresh_due; an unavailable connector must not mask it.
    const codexState = codexEnabled ? codex.connectorState
      : codexStates.includes('rate_limited') ? 'rate_limited'
        : codexStates.includes('refresh_due') ? 'refresh_due'
          : codexStates.includes('healthy') ? 'healthy' : 'unavailable';
    return json(res, 200, UnifiedUsage.parse({
      generatedAt: now, windows, estimates,
      connectors: {
        codex: codexState,
        claude: claudeState,
        // GLM, DeepSeek, and Google AI Studio have no ingestion path in this
        // tranche. They stay explicit and unavailable until a reviewed,
        // server-side connector supplies validated observations.
        glm: 'unavailable',
        deepseek: 'unavailable',
        google_ai_studio: 'unavailable',
      },
    }));
  }
  return json(res, 404, { error: 'not_found' });
}
export function createApiServer(
  readLive: typeof readCodexLive = readCodexLive,
  barcodeClient?: OpenFoodFactsClient,
  calendarStore: CalendarStore = new CalendarStore(),
) {
  const configuredBarcodeClient = barcodeClient ?? createConfiguredOpenFoodFactsClient();
  return createServer((req, res) => app(req, res, readLive, configuredBarcodeClient, calendarStore));
}

export type ApiRuntime = {
  stdin: {
    once(event: 'end', listener: () => void): unknown;
    removeListener?: (event: 'end', listener: () => void) => unknown;
    readableEnded?: boolean;
  };
  once(event: 'SIGTERM' | 'SIGINT', listener: () => void): unknown;
  removeListener?: (event: 'SIGTERM' | 'SIGINT', listener: () => void) => unknown;
  exitCode?: string | number | null;
};
export type StartedApiServer = {
  server: ReturnType<typeof createApiServer>;
  closed: Promise<void>;
  shutdown: () => Promise<void>;
};
export type StartApiServerOptions = {
  port?: number;
  readLive?: typeof readCodexLive;
  runtime?: ApiRuntime;
  calendarStore?: CalendarStore;
};

/** Validate, bind only to loopback, and install one idempotent graceful shutdown path. */
export async function startApiServer(options: StartApiServerOptions = {}): Promise<StartedApiServer> {
  if (!(await validateStartupConfiguration())) throw new Error('startup_configuration_invalid');
  const server = createApiServer(options.readLive ?? readCodexLive, undefined, options.calendarStore);
  const port = options.port ?? Number(process.env.PORT || 8787);
  try {
    await new Promise<void>((resolveListen, rejectListen) => {
      const onError = () => {
        server.removeListener('error', onError);
        rejectListen(new Error('startup_listen_failed'));
      };
      server.once('error', onError);
      server.listen(port, '127.0.0.1', () => {
        server.removeListener('error', onError);
        resolveListen();
      });
    });
  } catch {
    await new Promise<void>(resolveClose => server.close(() => resolveClose())).catch(() => undefined);
    throw new Error('startup_listen_failed');
  }

  let resolveClosed!: () => void;
  let rejectClosed!: (error: Error) => void;
  const closed = new Promise<void>((resolveClose, rejectClose) => {
    resolveClosed = resolveClose;
    rejectClosed = rejectClose;
  });
  let closePromise: Promise<void> | undefined;
  const runtime = options.runtime;
  const onShutdownSignal = () => { void shutdown().catch(() => { if (runtime) runtime.exitCode = 1; }); };
  const detach = () => {
    runtime?.stdin.removeListener?.('end', onShutdownSignal);
    runtime?.removeListener?.('SIGTERM', onShutdownSignal);
    runtime?.removeListener?.('SIGINT', onShutdownSignal);
  };
  const shutdown = () => {
    if (closePromise) return closePromise;
    closePromise = new Promise<void>((resolveClose, rejectClose) => {
      server.close(error => {
        detach();
        if (error) {
          const failure = new Error('shutdown_failed');
          rejectClosed(failure);
          rejectClose(failure);
          return;
        }
        if (runtime) runtime.exitCode = 0;
        resolveClosed();
        resolveClose();
      });
    });
    return closePromise;
  };
  if (runtime) {
    if (runtime.stdin.readableEnded) queueMicrotask(onShutdownSignal);
    else runtime.stdin.once('end', onShutdownSignal);
    runtime.once('SIGTERM', onShutdownSignal);
    runtime.once('SIGINT', onShutdownSignal);
  }
  return { server, closed, shutdown };
}

export async function runApiServer(runtime: ApiRuntime = process): Promise<void> {
  const started = await startApiServer({ runtime });
  await started.closed;
}

if (process.env.NODE_ENV !== 'test') {
  void runApiServer().catch(() => {
    process.stderr.write('startup_failed\n');
    process.exitCode = 1;
  });
}
