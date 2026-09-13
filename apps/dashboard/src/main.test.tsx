// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, describe, expect, it, vi } from 'vitest';

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
import App from './main';

type TestFetchInit = NonNullable<Parameters<typeof globalThis.fetch>[1]>;

const response = (body: unknown, ok = true) => ({
  ok,
  json: async () => body,
});
const removedProductPattern = new RegExp(['demo', 'ad' + 'visor'].join('|'), 'i');
const deferred = <T,>() => {
  let resolve!: (_value: T) => void;
  const promise = new Promise<T>(value => { resolve = value; });
  return { promise, resolve };
};

function testTimes() {
  const observedAt = new Date().toISOString();
  const resetAt = new Date(Date.now() + 60 * 60_000).toISOString();
  return { observedAt, resetAt };
}

function testUsage() {
  const { observedAt, resetAt } = testTimes();
  const provenance = {
    source: 'codex-app-server-test',
    observedAt,
    freshness: 'fresh' as const,
    official: true,
    quality: 'observed' as const,
    connectorState: 'healthy' as const,
  };
  return {
    generatedAt: observedAt,
    windows: [
      { provider: 'codex', window: 'five_hour', durationMinutes: 300, usedPercent: 42, resetAt, availability: 'observed', provenance },
      { provider: 'codex', window: 'seven_day', durationMinutes: 10_080, usedPercent: 31, availability: 'observed', provenance },
    ],
    estimates: [],
    connectors: {
      codex: 'healthy',
      claude: 'unavailable',
      glm: 'unavailable',
      deepseek: 'unavailable',
      google_ai_studio: 'unavailable',
    },
  };
}

function testCodex() {
  const { observedAt, resetAt } = testTimes();
  return {
    connectorState: 'healthy',
    observedAt,
    windows: [
      { minutes: 300, usedPercent: 42, resetAt },
      { minutes: 10_080, usedPercent: 31, resetAt },
    ],
  };
}

function unavailableFinance() {
  const generatedAt = new Date().toISOString();
  const provenance = {
    source: 'finance-connector-test',
    observedAt: generatedAt,
    freshness: 'unknown' as const,
    quality: 'unavailable' as const,
    connectorState: 'unavailable' as const,
  };
  const metric = { availability: 'unavailable' as const, provenance };
  return {
    generatedAt,
    currency: 'EUR' as const,
    monthlyIncome: metric,
    fixedCosts: metric,
    discretionaryBuffer: metric,
    spent: metric,
    savingsGoal: metric,
    saved: metric,
  };
}

function unavailableClipper() {
  const generatedAt = new Date().toISOString();
  return {
    schemaVersion: 1 as const,
    availability: 'unavailable' as const,
    generatedAt,
    currency: 'EUR' as const,
    provenance: {
      source: 'clipper-connector-test',
      observedAt: generatedAt,
      freshness: 'unknown' as const,
      quality: 'unavailable' as const,
      connectorState: 'unavailable' as const,
    },
  };
}

function navigationButton(host: HTMLDivElement, label: string): HTMLButtonElement {
  const button = Array.from(host.querySelectorAll<HTMLButtonElement>('.nav-button'))
    .find(candidate => candidate.textContent?.includes(label));
  if (!button) throw new Error('navigation button missing: ' + label);
  return button;
}

describe('dashboard live source states', () => {
  let root: Root | undefined;
  let host: HTMLDivElement;

  afterEach(async () => {
    await act(async () => { root?.unmount(); });
    document.body.replaceChildren();
    root = undefined;
    vi.restoreAllMocks();
  });

  it('loads live endpoints independently and renders compact unavailable states', async () => {
    const pending: Record<string, ReturnType<typeof deferred<ReturnType<typeof response>>>> = {
      '/api/usage': deferred<ReturnType<typeof response>>(),
      '/api/codex/live': deferred<ReturnType<typeof response>>(),
      '/api/finance/summary': deferred<ReturnType<typeof response>>(),
      '/api/clipper/summary': deferred<ReturnType<typeof response>>(),
    };
    const fetchMock = vi.fn((input: string, _init?: TestFetchInit) => pending[input]!.promise);
    vi.stubGlobal('fetch', fetchMock);
    host = document.createElement('div');
    document.body.append(host);

    await act(async () => {
      root = createRoot(host);
      root.render(<App />);
      await Promise.resolve();
    });
    expect(host.textContent).toContain('Connecting');
    expect(host.textContent).toContain('Loading');

    await act(async () => {
      pending['/api/usage'].resolve(response(testUsage()));
      pending['/api/codex/live'].resolve(response(testCodex()));
      pending['/api/finance/summary'].resolve(response(unavailableFinance()));
      pending['/api/clipper/summary'].resolve(response(unavailableClipper()));
      await Promise.all(Object.values(pending).map(item => item.promise));
    });

    expect(host.textContent).toContain('Today');
    expect(host.textContent).toContain('Codex');
    expect(host.textContent).toContain('42%');
    expect(host.textContent).toContain('No authorized account');
    await act(async () => { navigationButton(host, 'Finance').click(); });
    expect(host.textContent).toContain('Finance is not connected');
    expect(host.textContent).not.toMatch(removedProductPattern);
    expect(host.textContent).not.toContain('Signal overview');
    expect(host.textContent).not.toContain('READ-ONLY');
    expect(fetchMock).toHaveBeenCalledTimes(4);
    expect(fetchMock.mock.calls.map(([input]) => String(input))).toEqual(expect.arrayContaining([
      '/api/usage',
      '/api/codex/live',
      '/api/finance/summary',
      '/api/clipper/summary',
    ]));
    expect(fetchMock.mock.calls.every(([, init]) => {
      const headers = init?.headers as Record<string, string> | undefined;
      return headers?.Accept === 'application/json' && init?.method === 'GET';
    })).toBe(true);
  });

  it('keeps other modules visible when one live endpoint fails', async () => {
    const fetchMock = vi.fn((input: string) => {
      const path = input;
      if (path === '/api/usage') return Promise.reject(new Error('network'));
      if (path === '/api/codex/live') return Promise.resolve(response(testCodex()));
      if (path === '/api/finance/summary') return Promise.resolve(response(unavailableFinance()));
      return Promise.resolve(response(unavailableClipper()));
    });
    vi.stubGlobal('fetch', fetchMock);
    host = document.createElement('div');
    document.body.append(host);

    await act(async () => {
      root = createRoot(host);
      root.render(<App />);
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(host.querySelector('[role="alert"]')?.textContent).toContain('Usage is unavailable');
    await act(async () => { navigationButton(host, 'Usage').click(); });
    expect(host.textContent).toContain('Codex windows');
    expect(host.textContent).toContain('42%');
    expect(host.textContent).toContain('Clipper');
    expect(host.textContent).not.toMatch(removedProductPattern);
  });

  it('rejects malformed live data without blanking valid usage', async () => {
    const malformedCodex = {
      connectorState: 'healthy',
      windows: [{ minutes: 300, usedPercent: 140 }],
    };
    const fetchMock = vi.fn((input: string) => {
      const path = input;
      if (path === '/api/codex/live') return Promise.resolve(response(malformedCodex));
      if (path === '/api/usage') return Promise.resolve(response(testUsage()));
      if (path === '/api/finance/summary') return Promise.resolve(response(unavailableFinance()));
      return Promise.resolve(response(unavailableClipper()));
    });
    vi.stubGlobal('fetch', fetchMock);
    host = document.createElement('div');
    document.body.append(host);

    await act(async () => {
      root = createRoot(host);
      root.render(<App />);
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });

    await act(async () => { navigationButton(host, 'Usage').click(); });
    expect(host.textContent).toContain('Codex is unavailable');
    expect(host.textContent).toContain('5-hour window');
    expect(host.textContent).toContain('42%');
    expect(host.textContent).not.toMatch(removedProductPattern);
  });

  it('aborts in-flight source requests when the dashboard unmounts', async () => {
    const requests: TestFetchInit[] = [];
    const fetchMock = vi.fn((_input: string, init?: TestFetchInit) => {
      if (init) requests.push(init);
      return new Promise(() => undefined);
    });
    vi.stubGlobal('fetch', fetchMock);
    host = document.createElement('div');
    document.body.append(host);

    await act(async () => {
      root = createRoot(host);
      root.render(<App />);
      await Promise.resolve();
    });
    await act(async () => { root?.unmount(); });

    expect(requests).toHaveLength(4);
    expect(requests.every(init => init.signal?.aborted)).toBe(true);
  });
});
