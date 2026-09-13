import { describe, expect, it } from 'vitest';
import {
  ClipperSnapshot,
  parseClipperSnapshot,
  unavailableClipperSnapshot,
} from './clipper.js';

const observedAt = new Date(Date.now() - 30_000).toISOString();
const provenance = {
  source: 'reviewed-clipper-connector', observedAt, freshness: 'fresh' as const,
  quality: 'observed' as const, connectorState: 'healthy' as const,
};
const unavailableProvenance = {
  source: 'reviewed-clipper-connector', observedAt, freshness: 'unknown' as const,
  quality: 'unavailable' as const, connectorState: 'unavailable' as const,
};
const metrics = {
  views: { availability: 'observed' as const, value: 42_000, provenance },
  subscribers: { availability: 'observed' as const, value: 1_240, provenance },
  revenue: { availability: 'observed' as const, amountCents: 84_200, currency: 'EUR' as const, provenance },
};

function observedSnapshot(overrides: Record<string, unknown> = {}) {
  return {
    schemaVersion: 1,
    availability: 'observed' as const,
    generatedAt: observedAt,
    currency: 'EUR' as const,
    metrics,
    accounts: [{
      id: 'account-1', name: 'Primary account', metrics,
      bots: [{ id: 'bot-1', name: 'Daily clips', metrics, breakdowns: [] }],
      breakdowns: [],
    }],
    trends: [{ at: observedAt, metrics }],
    breakdowns: [{
      id: 'month-2026-08', label: 'August 2026',
      periodStart: '2026-08-01T00:00:00.000Z', periodEnd: '2026-09-01T00:00:00.000Z', metrics,
    }],
    provenance: { ...provenance },
    ...overrides,
  };
}

describe('ClipperSnapshot', () => {
  it('keeps the production default explicitly unavailable', () => {
    const snapshot = unavailableClipperSnapshot();
    expect(snapshot).toMatchObject({
      schemaVersion: 1, availability: 'unavailable', currency: 'EUR',
      provenance: { quality: 'unavailable', connectorState: 'unavailable' },
    });
    expect(snapshot).not.toHaveProperty('metrics');
    expect(snapshot).not.toHaveProperty('accounts');
  });

  it('accepts observed EUR revenue with account, bot, trend, and breakdown data', () => {
    const parsed = parseClipperSnapshot(observedSnapshot());
    expect(parsed.availability).toBe('observed');
    if (parsed.availability === 'observed') {
      expect(parsed.accounts[0].bots[0].metrics.revenue).toMatchObject({ amountCents: 84_200, currency: 'EUR' });
      expect(parsed.trends).toHaveLength(1);
      expect(parsed.breakdowns).toHaveLength(1);
    }
  });

  it('allows independently unavailable metrics without converting them to zero', () => {
    const partialMetrics = {
      views: metrics.views,
      subscribers: { availability: 'unavailable' as const, provenance: unavailableProvenance },
      revenue: { availability: 'unavailable' as const, currency: 'EUR' as const, provenance: unavailableProvenance },
    };
    const parsed = parseClipperSnapshot(observedSnapshot({ metrics: partialMetrics }));
    expect(parsed.availability).toBe('observed');
    if (parsed.availability === 'observed') {
      expect(parsed.metrics.subscribers.availability).toBe('unavailable');
      expect(parsed.metrics.revenue.availability).toBe('unavailable');
    }
  });

  it('rejects duplicate accounts, bots, and breakdown IDs', () => {
    const base = observedSnapshot();
    expect(() => ClipperSnapshot.parse({ ...base, accounts: [base.accounts[0], base.accounts[0]] })).toThrow();
    expect(() => ClipperSnapshot.parse({
      ...base,
      accounts: [{ ...base.accounts[0], bots: [base.accounts[0].bots[0], base.accounts[0].bots[0]] }],
    })).toThrow();
    expect(() => ClipperSnapshot.parse({
      ...base,
      breakdowns: [base.breakdowns[0], base.breakdowns[0]],
    })).toThrow();
  });

  it('rejects contradictory unavailable revenue, unsafe cents, and future observations', () => {
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      metrics: {
        ...metrics,
        revenue: { availability: 'unavailable', currency: 'EUR', amountCents: 0, provenance: unavailableProvenance },
      },
    })).toThrow();
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      metrics: { ...metrics, revenue: { ...metrics.revenue, amountCents: Number.MAX_SAFE_INTEGER + 1 } },
    })).toThrow();
    const future = new Date(Date.now() + 10_000).toISOString();
    expect(() => ClipperSnapshot.parse({ ...observedSnapshot(), generatedAt: future })).toThrow();
  });

  it('caps observed counts at the cross-language safe integer maximum', () => {
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      metrics: { ...metrics, views: { ...metrics.views, value: Number.MAX_SAFE_INTEGER + 1 } },
    })).toThrow();
  });

  it('requires top-level freshness and connector state to agree with provenance age', () => {
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      provenance: { ...provenance, freshness: 'stale', connectorState: 'refresh_due' },
    })).toThrow();
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      provenance: { ...provenance, connectorState: 'refresh_due' },
    })).toThrow();
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      provenance: {
        ...provenance,
        observedAt: new Date(Date.now() - 60 * 60_000).toISOString(),
        freshness: 'stale',
        connectorState: 'healthy',
      },
    })).toThrow();
  });

  it('rejects unsupported connector states and whitespace-only sources', () => {
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      provenance: { ...provenance, connectorState: 'disabled' },
    })).toThrow();
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot(),
      provenance: { ...provenance, source: '   ' },
    })).toThrow();
  });

  it('requires a real observed metric even for a partial observed snapshot', () => {
    const unavailableProvenance = {
      source: 'reviewed-clipper-connector', observedAt, freshness: 'unknown' as const,
      quality: 'unavailable' as const, connectorState: 'unavailable' as const,
    };
    const unavailableMetrics = {
      views: { availability: 'unavailable' as const, provenance: unavailableProvenance },
      subscribers: { availability: 'unavailable' as const, provenance: unavailableProvenance },
      revenue: { availability: 'unavailable' as const, currency: 'EUR' as const, provenance: unavailableProvenance },
    };
    expect(() => ClipperSnapshot.parse(observedSnapshot({
      metrics: unavailableMetrics,
      accounts: [],
      provenance: { ...provenance, quality: 'partial' },
    }))).toThrow();
  });

  it('requires generation to cover nested trend and provenance timestamps', () => {
    const nestedAt = new Date(Date.now() - 5_000).toISOString();
    const generatedAt = new Date(Date.now() - 30_000).toISOString();
    expect(() => ClipperSnapshot.parse({
      ...observedSnapshot({ generatedAt }),
      trends: [{ at: nestedAt, metrics }],
    })).toThrow();
  });
});
