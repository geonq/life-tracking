import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import {
  FinanceSummary,
  parseClipperSnapshot,
  UnifiedUsage,
  type ClipperMetricSet,
  type Provider,
  type UsageWindow,
} from '@iphone-life-os/contracts';
import './styles.css';

type Page = 'overview' | 'codex' | 'clipper' | 'health' | 'finance';
type UsageData = ReturnType<typeof UnifiedUsage.parse>;
type FinanceData = ReturnType<typeof FinanceSummary.parse>;
type ClipperData = ReturnType<typeof parseClipperSnapshot>;
type ResourceStatus = 'loading' | 'refreshing' | 'ready' | 'error';

type ResourceState<T> = {
  status: ResourceStatus;
  data?: T;
  error?: string;
};

type DashboardResources = {
  usage: ResourceState<UsageData>;
  codex: ResourceState<CodexLive>;
  finance: ResourceState<FinanceData>;
  clipper: ResourceState<ClipperData>;
};

type CodexWindow = {
  minutes: 300 | 10_080;
  usedPercent: number;
  resetAt?: string;
};

type CodexLive = {
  connectorState: 'healthy' | 'unavailable' | 'rate_limited';
  windows: CodexWindow[];
  observedAt?: string;
};

type ResourceKey = keyof DashboardResources;
type ResourceValue = UsageData | CodexLive | FinanceData | ClipperData;
type Tone = 'neutral' | 'success' | 'warning' | 'error';

const API = (import.meta.env.VITE_API_URL ?? '').replace(/\/$/, '');
type FetchSignal = NonNullable<NonNullable<Parameters<typeof globalThis.fetch>[1]>['signal']>;
const PROVIDERS: Provider[] = ['codex', 'claude', 'glm', 'deepseek', 'google_ai_studio'];
const NAV_ITEMS: Array<{ id: Page; label: string; icon: IconName }> = [
  { id: 'overview', label: 'Overview', icon: 'overview' },
  { id: 'codex', label: 'Usage', icon: 'usage' },
  { id: 'clipper', label: 'Clipper', icon: 'clipper' },
  { id: 'health', label: 'Health', icon: 'health' },
  { id: 'finance', label: 'Finance', icon: 'finance' },
];
const PAGE_META: Record<Page, { label: string; title: string; description: string }> = {
  overview: {
    label: 'Overview',
    title: 'Today',
    description: 'A compact view of the sources connected to your workspace.',
  },
  codex: {
    label: 'Usage',
    title: 'Usage',
    description: 'Live provider windows with their source and observation time.',
  },
  clipper: {
    label: 'Clipper',
    title: 'Clipper',
    description: 'Observed account analytics without combining providers.',
  },
  health: {
    label: 'Health',
    title: 'Health',
    description: 'HealthKit signals are read by the native LifeOS app.',
  },
  finance: {
    label: 'Finance',
    title: 'Finance',
    description: 'Balances and transactions from connected financial sources.',
  },
};

type IconName =
  | 'overview'
  | 'usage'
  | 'clipper'
  | 'health'
  | 'finance'
  | 'calendar'
  | 'refresh'
  | 'chevron'
  | 'database'
  | 'clock'
  | 'warning'
  | 'check';

const iconPaths: Record<IconName, ReactNode> = {
  overview: (
    <>
      <rect x="3.5" y="3.5" width="7" height="7" rx="1.2" />
      <rect x="13.5" y="3.5" width="7" height="7" rx="1.2" />
      <rect x="3.5" y="13.5" width="7" height="7" rx="1.2" />
      <rect x="13.5" y="13.5" width="7" height="7" rx="1.2" />
    </>
  ),
  usage: (
    <>
      <path d="M4 19V12" />
      <path d="M10 19V7" />
      <path d="M16 19V4" />
      <path d="M22 19H2" />
    </>
  ),
  clipper: (
    <>
      <path d="M3 17.5 8.2 12l3.6 3.1L21 6" />
      <path d="M16.5 6H21v4.5" />
      <path d="M3 20.5h18" />
    </>
  ),
  health: (
    <>
      <path d="M20.8 8.7c0 5.2-8.8 11-8.8 11s-8.8-5.8-8.8-11A4.7 4.7 0 0 1 12 6.2a4.7 4.7 0 0 1 8.8 2.5Z" />
      <path d="M8.2 12h2l1.2-2.3 1.5 4.6 1.2-2.3h2" />
    </>
  ),
  finance: (
    <>
      <rect x="3" y="5.2" width="18" height="13.6" rx="2" />
      <path d="M3 9.5h18" />
      <path d="M7 14.2h3.2" />
    </>
  ),
  calendar: (
    <>
      <rect x="3.5" y="5" width="17" height="15.5" rx="2" />
      <path d="M7.5 3.5v3" />
      <path d="M16.5 3.5v3" />
      <path d="M3.5 9h17" />
      <path d="M8 13h.01M12 13h.01M16 13h.01M8 16.5h.01M12 16.5h.01" />
    </>
  ),
  refresh: (
    <>
      <path d="M20 11a8 8 0 0 0-13.7-4.9L4 8.5" />
      <path d="M4 4.5v4h4" />
      <path d="M4 13a8 8 0 0 0 13.7 4.9l2.3-2.4" />
      <path d="M20 19.5v-4h-4" />
    </>
  ),
  chevron: <path d="m9 5 7 7-7 7" />,
  database: (
    <>
      <ellipse cx="12" cy="5.5" rx="7.5" ry="3" />
      <path d="M4.5 5.5v6c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3v-6" />
      <path d="M4.5 11.5v6c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3v-6" />
    </>
  ),
  clock: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7v5l3.2 2" />
    </>
  ),
  warning: (
    <>
      <path d="m12 3.5 9 16H3l9-16Z" />
      <path d="M12 9v4.5M12 16.5h.01" />
    </>
  ),
  check: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="m8 12 2.7 2.7L16.5 9" />
    </>
  ),
};

function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {iconPaths[name]}
    </svg>
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function parseTimestamp(value: unknown): string {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) {
    throw new Error('invalid_timestamp');
  }
  return new Date(value).toISOString();
}

function parseCodexLive(value: unknown): CodexLive {
  if (!isRecord(value)) throw new Error('invalid_codex_response');
  const connectorState = value.connectorState;
  if (connectorState !== 'healthy' && connectorState !== 'unavailable' && connectorState !== 'rate_limited') {
    throw new Error('invalid_codex_response');
  }
  if (!Array.isArray(value.windows) || value.windows.length > 2) {
    throw new Error('invalid_codex_response');
  }
  const seen = new Set<number>();
  const windows: CodexWindow[] = [];
  for (const candidate of value.windows) {
    if (!isRecord(candidate)) throw new Error('invalid_codex_response');
    const minutes = candidate.minutes;
    const usedPercent = candidate.usedPercent;
    if ((minutes !== 300 && minutes !== 10_080)
      || seen.has(minutes)
      || typeof usedPercent !== 'number'
      || !Number.isFinite(usedPercent)
      || usedPercent < 0
      || usedPercent > 100) {
      throw new Error('invalid_codex_response');
    }
    const resetAt = candidate.resetAt === undefined ? undefined : parseTimestamp(candidate.resetAt);
    seen.add(minutes);
    windows.push({
      minutes: minutes as CodexWindow['minutes'],
      usedPercent,
      ...(resetAt ? { resetAt } : {}),
    });
  }
  windows.sort((left, right) => left.minutes - right.minutes);
  const observedAt = value.observedAt === undefined ? undefined : parseTimestamp(value.observedAt);
  if (observedAt !== undefined && Date.parse(observedAt) > Date.now() + 5_000) {
    throw new Error('invalid_codex_response');
  }
  return { connectorState, windows, ...(observedAt ? { observedAt } : {}) };
}

async function requestJson<T>(
  path: string,
  parse: (_value: unknown) => T,
  signal: FetchSignal,
): Promise<T> {
  const response = await globalThis.fetch(API + path, {
    method: 'GET',
    headers: { Accept: 'application/json' },
    signal,
  });
  if (!response.ok) throw new Error('source_request_failed');
  return parse(await response.json());
}

function createInitialResources(): DashboardResources {
  return {
    usage: { status: 'loading' },
    codex: { status: 'loading' },
    finance: { status: 'loading' },
    clipper: { status: 'loading' },
  };
}

const RESOURCE_LABELS: Record<ResourceKey, string> = {
  usage: 'Usage',
  codex: 'Codex',
  finance: 'Finance',
  clipper: 'Clipper',
};

function useLiveData() {
  const [resources, setResources] = useState<DashboardResources>(createInitialResources);
  const [refreshID, setRefreshID] = useState(0);
  const refresh = useCallback(() => setRefreshID(value => value + 1), []);

  useEffect(() => {
    const controller = new globalThis.AbortController();
    let active = true;
    setResources(previous => ({
      usage: { status: previous.usage.data === undefined ? 'loading' : 'refreshing', data: previous.usage.data },
      codex: { status: previous.codex.data === undefined ? 'loading' : 'refreshing', data: previous.codex.data },
      finance: { status: previous.finance.data === undefined ? 'loading' : 'refreshing', data: previous.finance.data },
      clipper: { status: previous.clipper.data === undefined ? 'loading' : 'refreshing', data: previous.clipper.data },
    }));

    const finish = (key: ResourceKey, data: ResourceValue) => {
      if (!active) return;
      setResources(previous => ({
        ...previous,
        [key]: { status: 'ready', data },
      } as DashboardResources));
    };
    const fail = (key: ResourceKey) => {
      if (!active) return;
      setResources(previous => ({
        ...previous,
        [key]: {
          status: 'error',
          data: previous[key].data,
          error: RESOURCE_LABELS[key] + ' is unavailable right now. Try again when the source is reachable.',
        },
      } as DashboardResources));
    };

    void requestJson('/api/usage', value => UnifiedUsage.parse(value), controller.signal)
      .then(value => finish('usage', value))
      .catch(() => fail('usage'));
    void requestJson('/api/codex/live', parseCodexLive, controller.signal)
      .then(value => finish('codex', value))
      .catch(() => fail('codex'));
    void requestJson('/api/finance/summary', value => FinanceSummary.parse(value), controller.signal)
      .then(value => finish('finance', value))
      .catch(() => fail('finance'));
    void requestJson('/api/clipper/summary', parseClipperSnapshot, controller.signal)
      .then(value => finish('clipper', value))
      .catch(() => fail('clipper'));

    return () => {
      active = false;
      controller.abort();
    };
  }, [refreshID]);

  const busy = Object.values(resources).some(resource =>
    resource.status === 'loading' || resource.status === 'refreshing');
  return { resources, refresh, busy };
}

function App() {
  const [page, setPage] = useState<Page>('overview');
  const { resources, refresh, busy } = useLiveData();
  const meta = PAGE_META[page];
  const status = useMemo(() => summarizeResources(resources), [resources]);

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark"><Icon name="overview" size={16} /></span>
          <span className="brand-name">LifeOS</span>
        </div>
        <p className="brand-caption">Private workspace</p>
        <nav className="primary-nav" aria-label="Primary navigation">
          {NAV_ITEMS.map(item => (
            <button
              type="button"
              key={item.id}
              className={'nav-button' + (page === item.id ? ' is-selected' : '')}
              aria-current={page === item.id ? 'page' : undefined}
              title={item.label}
              onClick={() => setPage(item.id)}
            >
              <span className="nav-icon"><Icon name={item.icon} /></span>
              <span className="nav-copy">{item.label}</span>
            </button>
          ))}
        </nav>
        <div className="sidebar-status">
          <span className={'status-dot status-dot-' + status.tone} />
          <span>{status.label}</span>
        </div>
      </aside>

      <div className="app-body">
        <main className="content">
          <header className="page-header">
            <div className="page-heading">
              <p className="breadcrumb">LifeOS <span>/</span> {meta.label}</p>
              <h1>{meta.title}</h1>
              <p className="page-description">{meta.description}</p>
            </div>
            <div className="page-actions">
              <StatusChip label={status.label} tone={status.tone} />
              <button
                type="button"
                className="icon-button"
                aria-label={busy ? 'Updating sources' : 'Refresh sources'}
                title={busy ? 'Updating sources' : 'Refresh sources'}
                onClick={refresh}
                disabled={busy}
              >
                <Icon name="refresh" />
              </button>
            </div>
          </header>

          <div className="route-view" key={page}>
            {page === 'overview' && <OverviewPage resources={resources} navigate={setPage} />}
            {page === 'codex' && <CodexPage resources={resources} />}
            {page === 'clipper' && <ClipperPage resource={resources.clipper} />}
            {page === 'health' && <HealthPage />}
            {page === 'finance' && <FinancePage resource={resources.finance} />}
          </div>
        </main>
      </div>
    </div>
  );
}

function summarizeResources(resources: DashboardResources): { label: string; tone: Tone } {
  const list = Object.values(resources);
  if (list.some(resource => resource.status === 'loading')) {
    return { label: 'Connecting', tone: 'neutral' };
  }
  if (list.some(resource => resource.status === 'refreshing')) {
    return { label: 'Updating', tone: 'neutral' };
  }
  if (list.some(resource => resource.status === 'error')) {
    return { label: 'Needs attention', tone: 'warning' };
  }
  const connectedSources = new Set<string>();
  for (const window of resources.usage.data?.windows ?? []) {
    if (window.availability === 'observed') connectedSources.add(window.provider);
  }
  if (resources.codex.data?.windows.length) connectedSources.add('codex');
  if (resources.finance.data !== undefined && financeHasObservedValue(resources.finance.data)) connectedSources.add('finance');
  if (resources.clipper.data?.availability === 'observed') connectedSources.add('clipper');
  const connected = connectedSources.size;
  return connected > 0
    ? { label: connected + ' source' + (connected === 1 ? '' : 's') + ' connected', tone: 'success' }
    : { label: 'No connected sources', tone: 'neutral' };
}

function StatusChip({ label, tone }: { label: string; tone: Tone }) {
  return <span className={'status-chip status-chip-' + tone}><span className="status-chip-dot" />{label}</span>;
}

function OverviewPage({
  resources,
  navigate,
}: {
  resources: DashboardResources;
  navigate: (_page: Page) => void;
}) {
  return (
    <div className="page-stack">
      <section className="overview-layout">
        <article className="panel agenda-panel">
          <PanelHeading icon="calendar" eyebrow="Planning" title="Today’s plan" />
          <div className="compact-empty">
            <span className="empty-icon"><Icon name="calendar" size={18} /></span>
            <div>
              <strong>Calendar data is not available here</strong>
              <p>Use the native LifeOS calendar to view and edit your agenda.</p>
            </div>
          </div>
        </article>
        <UsagePanel resource={resources.usage} navigate={navigate} />
      </section>

      <section className="section-block">
        <SectionHeading eyebrow="Connected modules" title="Signals from your day" />
        <div className="module-grid">
          <ModuleCard
            icon="finance"
            title="Finance"
            description="Balances and spending"
            onClick={() => navigate('finance')}
          >
            <FinanceModuleSummary resource={resources.finance} />
          </ModuleCard>
          <ModuleCard
            icon="clipper"
            title="Clipper"
            description="Account analytics"
            onClick={() => navigate('clipper')}
          >
            <ClipperModuleSummary resource={resources.clipper} />
          </ModuleCard>
          <ModuleCard
            icon="health"
            title="Health"
            description="HealthKit signals"
            onClick={() => navigate('health')}
          >
            <p className="module-muted">Available in the native app.</p>
          </ModuleCard>
        </div>
      </section>
    </div>
  );
}

function UsagePanel({
  resource,
  navigate,
}: {
  resource: ResourceState<UsageData>;
  navigate: (_page: Page) => void;
}) {
  return (
    <article className="panel usage-panel">
      <div className="panel-heading panel-heading-with-action">
        <PanelHeading icon="usage" eyebrow="Observed limits" title="Usage" />
        <button type="button" className="text-button" onClick={() => navigate('codex')}>
          Open details <Icon name="chevron" size={14} />
        </button>
      </div>
      {resource.error && resource.data && <InlineNotice tone="warning">{resource.error}</InlineNotice>}
      {resource.data
        ? <UsageProviderList usage={resource.data} compact />
        : <ResourceBody resource={resource} label="usage" />}
    </article>
  );
}

function UsageProviderList({ usage, compact = false }: { usage: UsageData; compact?: boolean }) {
  const providers = PROVIDERS.filter(provider =>
    usage.windows.some(window => window.provider === provider)
      || usage.connectors[provider] !== 'unavailable');
  if (providers.length === 0) {
    return (
      <div className="compact-empty">
        <span className="empty-icon"><Icon name="database" size={18} /></span>
        <div>
          <strong>No usage windows are available</strong>
          <p>The connected providers have not returned an observation.</p>
        </div>
      </div>
    );
  }
  return (
    <div className={'provider-list' + (compact ? ' is-compact' : '')}>
      {providers.map(provider => (
        <UsageProviderRow
          key={provider}
          provider={provider}
          windows={usage.windows.filter(window => window.provider === provider)}
          estimates={usage.estimates.filter(estimate => estimate.provider === provider)}
          connectorState={usage.connectors[provider]}
        />
      ))}
      <p className="panel-footnote">Provider windows stay separate and are never added together.</p>
    </div>
  );
}

function UsageProviderRow({
  provider,
  windows,
  estimates,
  connectorState,
}: {
  provider: Provider;
  windows: UsageWindow[];
  estimates: UsageData['estimates'];
  connectorState: string;
}) {
  const latest = windows.reduce<string | undefined>((current, window) => {
    const observedAt = window.provenance.observedAt;
    return current === undefined || Date.parse(observedAt) > Date.parse(current) ? observedAt : current;
  }, undefined);
  return (
    <article className="provider-row">
      <div className="provider-heading">
        <div className="provider-name">
          <span className="provider-icon"><Icon name="usage" size={16} /></span>
          <div>
            <h3>{providerLabel(provider)}</h3>
            <span className="provider-status">{connectorLabel(connectorState)}</span>
          </div>
        </div>
        {latest && <span className="provider-observed">Observed {formatDate(latest)}</span>}
      </div>
      <div className="usage-window-list">
        {(['five_hour', 'seven_day'] as const).map(kind => {
          const window = windows.find(candidate => candidate.window === kind);
          return <UsageWindowRow key={kind} window={window} />;
        })}
      </div>
      {estimates.length > 0 && <EstimateList estimates={estimates} />}
      {windows.length > 0 && (
        <details className="source-disclosure">
          <summary>Source details</summary>
          <p>{Array.from(new Set(windows.map(window => window.provenance.source))).join(' · ')}</p>
        </details>
      )}
    </article>
  );
}

function UsageWindowRow({ window }: { window: UsageWindow | undefined }) {
  if (!window || window.availability === 'unavailable') {
    return (
      <div className="usage-window is-unavailable">
        <div className="window-label">
          <strong>{windowLabel(window?.window)}</strong>
          <span>No observed value</span>
        </div>
        <strong className="window-value">—</strong>
      </div>
    );
  }
  const value = window.usedPercent;
  if (value === undefined) {
    return (
      <div className="usage-window is-unavailable">
        <div className="window-label">
          <strong>{windowLabel(window.window)}</strong>
          <span>No observed value</span>
        </div>
        <strong className="window-value">—</strong>
      </div>
    );
  }
  return (
    <div className="usage-window">
      <div className="window-label">
        <strong>{windowLabel(window.window)}</strong>
        <span>{capitalize(window.provenance.freshness)} · observed {formatDate(window.provenance.observedAt)}</span>
        {window.resetAt && <span>Resets {formatDate(window.resetAt)}</span>}
      </div>
      <div className="window-value">
        <strong>{formatPercent(value)}<small>% used</small></strong>
        <div className="usage-bar" role="progressbar" aria-label={windowLabel(window.window)} aria-valuemin={0} aria-valuemax={100} aria-valuenow={value}>
          <span style={{ width: formatPercent(value) + '%' }} />
        </div>
      </div>
    </div>
  );
}

function EstimateList({ estimates }: { estimates: UsageData['estimates'] }) {
  return (
    <div className="estimate-list">
      {estimates.map(estimate => (
        <div className="estimate-line" key={estimate.provider + ':' + estimate.window}>
          <span>Estimate</span>
          <strong>
            {estimate.projectedPercentAtReset === undefined
              ? estimate.estimatedExhaustionAt
                ? 'Exhaustion ' + formatDate(estimate.estimatedExhaustionAt)
                : 'Insufficient history'
              : formatPercent(estimate.projectedPercentAtReset) + '% at reset'}
          </strong>
          <span>{capitalize(estimate.confidence)} confidence</span>
        </div>
      ))}
    </div>
  );
}

function CodexPage({ resources }: { resources: DashboardResources }) {
  const resource = resources.codex;
  const usage = resources.usage;
  return (
    <div className="page-stack">
      {resource.error && resource.data && <InlineNotice tone="warning">{resource.error}</InlineNotice>}
      <section className="panel">
        <PanelHeading icon="usage" eyebrow="Live connector" title="Codex windows" />
        {resource.data === undefined
          ? <ResourceBody resource={resource} label="Codex" />
          : resource.data.windows.length === 0
            ? <SourceState title="Codex has no supported window" description="The live connector did not return an observation for a supported limit." tone="neutral" icon="database" />
            : <CodexLiveWindows data={resource.data} />}
      </section>
      <section className="panel">
        <PanelHeading icon="clock" eyebrow="Stored observations" title="History and estimates" />
        {usage.data
          ? <CodexHistory usage={usage.data} />
          : <ResourceBody resource={usage} label="usage history" />}
      </section>
    </div>
  );
}

function CodexLiveWindows({ data }: { data: CodexLive }) {
  return (
    <div className="provider-row provider-row-detail">
      <div className="provider-heading">
        <div className="provider-name">
          <span className="provider-icon"><Icon name="check" size={16} /></span>
          <div>
            <h3>Codex</h3>
            <span className="provider-status">{connectorLabel(data.connectorState)}</span>
          </div>
        </div>
        {data.observedAt && <span className="provider-observed">Observed {formatDate(data.observedAt)}</span>}
      </div>
      <div className="usage-window-list">
        {data.windows.map(window => (
          <div className="usage-window" key={window.minutes}>
            <div className="window-label">
              <strong>{windowLabel(window.minutes === 300 ? 'five_hour' : 'seven_day')}</strong>
              <span>Live observation from the Codex connector</span>
              {window.resetAt && <span>Resets {formatDate(window.resetAt)}</span>}
            </div>
            <div className="window-value">
              <strong>{formatPercent(window.usedPercent)}<small>% used</small></strong>
              <div className="usage-bar" role="progressbar" aria-label={windowLabel(window.minutes === 300 ? 'five_hour' : 'seven_day')} aria-valuemin={0} aria-valuemax={100} aria-valuenow={window.usedPercent}>
                <span style={{ width: formatPercent(window.usedPercent) + '%' }} />
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function CodexHistory({ usage }: { usage: UsageData }) {
  const windows = usage.windows.filter(window => window.provider === 'codex');
  const estimates = usage.estimates.filter(estimate => estimate.provider === 'codex');
  if (windows.length === 0 && estimates.length === 0) {
    return <SourceState title="No stored Codex observations" description="History will appear after the connector records a valid observation." tone="neutral" icon="clock" />;
  }
  return (
    <div className="history-list">
      {windows.length > 0 && (
        <UsageProviderRow
          provider="codex"
          windows={windows}
          estimates={[]}
          connectorState={usage.connectors.codex}
        />
      )}
      {estimates.length > 0 && <EstimateList estimates={estimates} />}
    </div>
  );
}

function ClipperPage({ resource }: { resource: ResourceState<ClipperData> }) {
  return (
    <div className="page-stack">
      <section className="panel">
        <PanelHeading icon="clipper" eyebrow="Observed analytics" title="Account performance" />
        {resource.error && resource.data && <InlineNotice tone="warning">{resource.error}</InlineNotice>}
        {resource.data === undefined
          ? <ResourceBody resource={resource} label="Clipper" />
          : resource.data.availability === 'unavailable'
            ? <SourceState title="Clipper is not connected" description="Connect an authorized account to see analytics here." tone="neutral" icon="database" />
            : <ClipperSummary data={resource.data} />}
      </section>
    </div>
  );
}

function ClipperSummary({ data }: { data: Extract<ClipperData, { availability: 'observed' }> }) {
  const observedTrend = data.trends
    .map(point => point.metrics.views.availability === 'observed' ? { at: point.at, value: point.metrics.views.value } : undefined)
    .filter((point): point is { at: string; value: number } => point !== undefined);
  return (
    <>
      <div className="metric-grid metric-grid-three">
        <ClipperMetric label="Views" metric={data.metrics.views} />
        <ClipperMetric label="Subscribers" metric={data.metrics.subscribers} />
        <ClipperMetric label="Revenue" metric={data.metrics.revenue} revenue />
      </div>
      <div className="source-summary">
        <span className="source-summary-icon"><Icon name="check" size={14} /></span>
        <span>Observed {formatDate(data.provenance.observedAt)} · {capitalize(data.provenance.freshness)}</span>
      </div>
      {observedTrend.length > 0 && (
        <div className="trend-block">
          <div className="trend-heading">
            <span>Views trend</span>
            <span>{observedTrend.length} observations</span>
          </div>
          <MiniTrend values={observedTrend.map(point => point.value)} label="Observed views trend" />
        </div>
      )}
      {data.accounts.length > 0 && (
        <details className="source-disclosure">
          <summary>{data.accounts.length} connected account{data.accounts.length === 1 ? '' : 's'}</summary>
          <div className="account-list">
            {data.accounts.map(account => <span key={account.id}>{account.name}</span>)}
          </div>
        </details>
      )}
      <details className="source-disclosure">
        <summary>Source details</summary>
        <p>{data.provenance.source} · {formatDate(data.generatedAt)}</p>
      </details>
    </>
  );
}

function ClipperMetric({
  label,
  metric,
  revenue = false,
}: {
  label: string;
  metric: ClipperMetricSet['views'] | ClipperMetricSet['subscribers'] | ClipperMetricSet['revenue'];
  revenue?: boolean;
}) {
  const value = revenue && 'amountCents' in metric
    ? formatEUR(metric.amountCents)
    : 'value' in metric ? formatInteger(metric.value) : '—';
  return (
    <div className="metric-cell">
      <span>{label}</span>
      <strong>{value}</strong>
      <small>Observed</small>
    </div>
  );
}

function FinancePage({ resource }: { resource: ResourceState<FinanceData> }) {
  const data = resource.data;
  return (
    <div className="page-stack">
      {resource.error && data && <InlineNotice tone="warning">{resource.error}</InlineNotice>}
      <section className="panel">
        <PanelHeading icon="finance" eyebrow="Connected accounts" title="Finance" />
        {data === undefined
          ? <ResourceBody resource={resource} label="Finance" />
          : <FinanceSummaryView data={data} />}
      </section>
    </div>
  );
}

type FinanceMetricKey = 'monthlyIncome' | 'fixedCosts' | 'discretionaryBuffer' | 'spent' | 'savingsGoal' | 'saved';
const FINANCE_METRICS: Array<{ key: FinanceMetricKey; label: string }> = [
  { key: 'monthlyIncome', label: 'Monthly income' },
  { key: 'fixedCosts', label: 'Fixed costs' },
  { key: 'discretionaryBuffer', label: 'Buffer' },
  { key: 'spent', label: 'Spent' },
  { key: 'savingsGoal', label: 'Savings goal' },
  { key: 'saved', label: 'Saved' },
];

function financeHasObservedValue(data: FinanceData): boolean {
  return FINANCE_METRICS.some(item => data[item.key].availability === 'observed')
    || data.accounts?.availability === 'observed'
    || data.transactions?.availability === 'observed';
}

function FinanceSummaryView({ data }: { data: FinanceData }) {
  const hasValues = financeHasObservedValue(data);
  return hasValues
    ? (
      <div className="finance-content">
        <div className="metric-grid metric-grid-three">
          {FINANCE_METRICS.map(item => (
            <FinanceMetric key={item.key} label={item.label} metric={data[item.key]} />
          ))}
        </div>
        {data.accounts?.availability === 'observed' && (
          <div className="subsection">
            <SectionHeading eyebrow="Accounts" title="Balances" />
            <div className="account-list account-list-rows">
              {data.accounts.accounts.map(account => (
                <div className="account-row" key={account.id}>
                  <div><strong>{account.name}</strong><span>{account.detail}</span></div>
                  <strong>{account.availability === 'observed' ? formatEUR(account.balanceCents) : '—'}</strong>
                </div>
              ))}
            </div>
          </div>
        )}
        {data.transactions?.availability === 'observed' && data.transactions.transactions.length > 0 && (
          <div className="subsection">
            <SectionHeading eyebrow="Transactions" title="Recent activity" />
            <div className="transaction-list">
              {data.transactions.transactions.slice(0, 5).map(transaction => (
                <div className="transaction-row" key={transaction.id}>
                  <div><strong>{transaction.merchant}</strong><span>{transaction.category} · {formatDate(transaction.timestamp)}</span></div>
                  <strong className={transaction.signedAmountCents < 0 ? 'amount-outflow' : 'amount-inflow'}>{formatSignedEUR(transaction.signedAmountCents)}</strong>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    )
    : <SourceState title="Finance is not connected" description="Connect an authorized account to see balances and transactions." tone="neutral" icon="finance" />;
}

function FinanceMetric({
  label,
  metric,
}: {
  label: string;
  metric: FinanceData[FinanceMetricKey];
}) {
  return (
    <div className="metric-cell">
      <span>{label}</span>
      <strong>{metric.availability === 'observed' ? formatEUR(metric.amountCents) : '—'}</strong>
      <small>{metric.availability === 'observed' ? 'Observed' : 'Unavailable'}</small>
    </div>
  );
}

function HealthPage() {
  return (
    <div className="page-stack">
      <section className="panel">
        <PanelHeading icon="health" eyebrow="Native source" title="Health" />
        <SourceState title="Health data is available in the native app" description="This dashboard does not have a HealthKit data endpoint." tone="neutral" icon="health" />
      </section>
    </div>
  );
}

function FinanceModuleSummary({ resource }: { resource: ResourceState<FinanceData> }) {
  if (!resource.data) return <ModuleState resource={resource} empty="Waiting for the finance source." />;
  if (!financeHasObservedValue(resource.data)) return <ModuleState resource={resource} empty="No authorized account." />;
  const observed = FINANCE_METRICS.find(item => resource.data?.[item.key].availability === 'observed');
  if (observed) {
    const metric = resource.data[observed.key];
    if (metric.availability === 'observed') {
      return <><strong className="module-value">{formatEUR(metric.amountCents)}</strong><span className="module-meta">{observed.label}</span></>;
    }
  }
  return <ModuleState resource={resource} empty="Accounts connected." />;
}

function ClipperModuleSummary({ resource }: { resource: ResourceState<ClipperData> }) {
  if (!resource.data) return <ModuleState resource={resource} empty="Waiting for the analytics source." />;
  if (resource.data.availability === 'unavailable') return <ModuleState resource={resource} empty="No authorized account." />;
  return resource.data.metrics.views.availability === 'observed'
    ? <><strong className="module-value">{formatInteger(resource.data.metrics.views.value)}</strong><span className="module-meta">Views observed</span></>
    : <ModuleState resource={resource} empty="No view observation." />;
}

function ModuleCard({
  icon,
  title,
  description,
  children,
  onClick,
}: {
  icon: IconName;
  title: string;
  description: string;
  children: ReactNode;
  onClick: () => void;
}) {
  return (
    <button type="button" className="module-card" onClick={onClick}>
      <div className="module-card-heading">
        <span className="module-icon"><Icon name={icon} size={17} /></span>
        <span className="module-card-title"><strong>{title}</strong><small>{description}</small></span>
        <Icon name="chevron" size={15} />
      </div>
      <div className="module-card-content">{children}</div>
    </button>
  );
}

function ModuleState({ resource, empty }: { resource: ResourceState<unknown>; empty: string }) {
  if (resource.error) return <span className="module-error">{resource.error}</span>;
  if (resource.status === 'loading' || resource.status === 'refreshing') return <span className="module-muted">Loading source…</span>;
  return <span className="module-muted">{empty}</span>;
}

function PanelHeading({ icon, eyebrow, title }: { icon: IconName; eyebrow: string; title: string }) {
  return (
    <div className="panel-heading">
      <span className="panel-icon"><Icon name={icon} size={16} /></span>
      <div>
        <p className="eyebrow">{eyebrow}</p>
        <h2>{title}</h2>
      </div>
    </div>
  );
}

function SectionHeading({ eyebrow, title }: { eyebrow: string; title: string }) {
  return (
    <div className="section-heading">
      <p className="eyebrow">{eyebrow}</p>
      <h2>{title}</h2>
    </div>
  );
}

function ResourceBody<T>({ resource, label }: { resource: ResourceState<T>; label: string }) {
  if (resource.status === 'loading' || resource.status === 'refreshing') {
    return <LoadingState label={label} />;
  }
  return (
    <SourceState
      title={resource.error ?? label + ' is unavailable'}
      description="The source did not return usable data."
      tone="error"
      icon="warning"
    />
  );
}

function LoadingState({ label }: { label: string }) {
  return (
    <div className="loading-state" aria-label={'Loading ' + label}>
      <span className="loading-bar loading-bar-short" />
      <span className="loading-bar" />
      <span className="loading-bar loading-bar-medium" />
    </div>
  );
}

function SourceState({
  title,
  description,
  tone,
  icon,
}: {
  title: string;
  description: string;
  tone: Tone;
  icon: IconName;
}) {
  return (
    <div className={'resource-state resource-state-' + tone} role={tone === 'error' ? 'alert' : undefined}>
      <span className="resource-state-icon"><Icon name={icon} size={16} /></span>
      <div>
        <strong>{title}</strong>
        <p>{description}</p>
      </div>
    </div>
  );
}

function InlineNotice({ tone, children }: { tone: Tone; children: ReactNode }) {
  return <p className={'inline-notice inline-notice-' + tone} role="status">{children}</p>;
}

function MiniTrend({ values, label }: { values: number[]; label: string }) {
  if (values.length === 0) return null;
  const width = 480;
  const height = 112;
  const padding = 8;
  const min = values.reduce((current, value) => Math.min(current, value), values[0]!);
  const max = values.reduce((current, value) => Math.max(current, value), values[0]!);
  const span = max - min || 1;
  const points = values.map((value, index) => {
    const x = values.length === 1 ? width / 2 : padding + (index / (values.length - 1)) * (width - padding * 2);
    const y = height - padding - ((value - min) / span) * (height - padding * 2);
    return [x, y] as const;
  });
  const path = points.map(([x, y], index) => (index === 0 ? 'M' : 'L') + ' ' + x.toFixed(2) + ' ' + y.toFixed(2)).join(' ');
  return (
    <svg className="trend-chart" viewBox={'0 0 ' + width + ' ' + height} role="img" aria-label={label}>
      <path className="trend-grid-line" d={'M ' + padding + ' ' + (height - padding) + ' H ' + (width - padding)} />
      <path className="trend-line" d={path} />
      {points.length === 1 && <circle className="trend-point" cx={points[0]![0]} cy={points[0]![1]} r="3" />}
    </svg>
  );
}

function providerLabel(provider: Provider): string {
  return {
    codex: 'Codex',
    claude: 'Claude',
    glm: 'GLM',
    deepseek: 'DeepSeek',
    google_ai_studio: 'Google AI Studio',
  }[provider];
}

function connectorLabel(state: string): string {
  return {
    healthy: 'Connected',
    refresh_due: 'Refresh needed',
    reauth_required: 'Reconnect required',
    revoked: 'Access revoked',
    rate_limited: 'Rate limited',
    unavailable: 'Unavailable',
  }[state] ?? 'Unavailable';
}

function windowLabel(window: 'five_hour' | 'seven_day' | undefined): string {
  return window === 'five_hour' ? '5-hour window' : window === 'seven_day' ? '7-day window' : 'Window';
}

function formatDate(value: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return 'Unknown time';
  return new Intl.DateTimeFormat(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(date);
}

function formatPercent(value: number): string {
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(value);
}

function formatInteger(value: number): string {
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(value);
}

const euroFormatter = new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'EUR' });

function formatEUR(cents: number): string {
  return euroFormatter.format(cents / 100);
}

function formatSignedEUR(cents: number): string {
  return (cents < 0 ? '−' : '+') + euroFormatter.format(Math.abs(cents) / 100);
}

function capitalize(value: string): string {
  return value.length === 0 ? value : value[0]!.toUpperCase() + value.slice(1);
}

export default App;
