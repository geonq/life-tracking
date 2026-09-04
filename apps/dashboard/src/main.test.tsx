// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, describe, expect, it, vi } from 'vitest';

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
import { fixtures } from '@iphone-life-os/contracts';
import App from './main';

const response = (body: unknown, ok = true) => ({ ok, json: async () => body });
const observedAt = new Date(Date.now() - 5 * 60_000).toISOString();
const resetAt = new Date(Date.now() + 3 * 60 * 60_000).toISOString();
const unifiedUsage = {
  generatedAt: new Date().toISOString(),
  windows: [
    { provider: 'codex', window: 'five_hour', durationMinutes: 300, usedPercent: 42, resetAt, availability: 'observed', provenance: { source: 'codex-official', observedAt, freshness: 'fresh', official: true, quality: 'observed', connectorState: 'healthy' } },
    { provider: 'codex', window: 'seven_day', durationMinutes: 10080, usedPercent: 31, availability: 'observed', provenance: { source: 'codex-official', observedAt, freshness: 'fresh', official: true, quality: 'observed', connectorState: 'healthy' } },
    { provider: 'claude', window: 'five_hour', durationMinutes: 300, availability: 'unavailable', provenance: { source: 'claude-connector', observedAt, freshness: 'unknown', official: false, quality: 'unavailable', connectorState: 'unavailable' } },
    { provider: 'claude', window: 'seven_day', durationMinutes: 10080, availability: 'unavailable', provenance: { source: 'claude-connector', observedAt, freshness: 'unknown', official: false, quality: 'unavailable', connectorState: 'unavailable' } },
  ],
  estimates: [{ provider: 'codex', window: 'seven_day', projectedPercentAtReset: 41, confidence: 'insufficient', sampleSpanHours: 4, explanation: 'Insufficient history', official: false }],
  connectors: { codex: 'healthy', claude: 'unavailable', glm: 'unavailable', deepseek: 'unavailable', google_ai_studio: 'unavailable' },
};

describe('dashboard API states and honesty labels', () => {
  let root: Root | undefined;
  let host: HTMLDivElement;
  afterEach(async () => {
    await act(async () => { root?.unmount(); });
    document.body.replaceChildren();
    root = undefined;
    vi.restoreAllMocks();
  });

  it('shows loading, then the typed Demo payload and blocked category states', async () => {
    let resolveOverview!: (_value: unknown) => void;
    let resolveCodex!: (_value: unknown) => void;
    let resolveUsage!: (_value: unknown) => void;
    const overview = new Promise(resolve => { resolveOverview = resolve; });
    const codex = new Promise(resolve => { resolveCodex = resolve; });
    const usage = new Promise(resolve => { resolveUsage = resolve; });
    const fetchMock = vi.fn((url: string) => url.endsWith('/overview') ? overview : url.endsWith('/codex') ? codex : usage);
    vi.stubGlobal('fetch', fetchMock);
    host = document.createElement('div'); document.body.append(host);
    await act(async () => { root = createRoot(host); root.render(<App />); });
    expect(host.textContent).toContain('Loading verified API data');
    await act(async () => {
      resolveOverview(response(fixtures.overview));
      resolveCodex(response(fixtures.codex));
      resolveUsage(response(unifiedUsage));
      await Promise.resolve(); await Promise.resolve();
    });
    expect(host.textContent).toContain('Demo data');
    expect(host.textContent).toContain('Signal overview');
    expect(host.textContent).toContain('Codex + Claude limits');
    expect(host.textContent).toContain('Codex');
    expect(host.textContent).toContain('Claude');
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(fetchMock).toHaveBeenCalledWith('/api/overview');
    expect(fetchMock).toHaveBeenCalledWith('/api/codex');
    expect(fetchMock).toHaveBeenCalledWith('/api/usage');
    expect(host.textContent).toContain('Official observed');
    expect(host.textContent).toContain('Unavailable · no observed value');
    expect(host.textContent).toContain('Nonofficial estimate');
    expect(host.textContent).toContain('insufficient history');
    expect(host.textContent).not.toContain('Combined total');
    for (const category of ['Clipper', 'Health', 'Finance']) {
      await act(async () => { (Array.from(host.querySelectorAll('button')).find(b => b.textContent?.startsWith(category)) as HTMLButtonElement).click(); });
      expect(host.textContent).toContain(`${category} · SOURCE BLOCKER`);
      expect(host.textContent).toContain('no invented metrics');
    }
  });

  it('shows an actionable error for unavailable and malformed API responses', async () => {
    const fetchMock = vi.fn((url: string) => Promise.resolve(response(url.endsWith('/overview') ? {} : url.endsWith('/codex') ? fixtures.codex : unifiedUsage)));
    vi.stubGlobal('fetch', fetchMock);
    host = document.createElement('div'); document.body.append(host);
    await act(async () => {
      root = createRoot(host);
      root.render(<App />);
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(host.querySelector('[role="alert"]')?.textContent).toContain('unavailable');
    expect(host.textContent).toContain('READ-ONLY · DEMO DATA');
  });
});
