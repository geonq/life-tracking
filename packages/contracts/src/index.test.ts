import { describe, expect, it } from 'vitest';
import { normalizeWindow, UnifiedUsage, UsageHistoryEntry, UsageProvenance, UsageWindow } from './usage.js';
import {
  ConnectorState, FinanceConnectorCatalog, FinanceConnectorDescriptor,
  FinanceSummary, parseOverview, fixtures,
} from './index.js';
describe('contracts',()=>{ it('accepts truthful fixture',()=>expect(parseOverview(fixtures.overview).label).toBe('Demo data')); it('rejects invalid connector state',()=>expect(()=>ConnectorState.parse('connected')).toThrow()); it('requires provenance',()=>expect(()=>parseOverview({...fixtures.overview,codex:{...fixtures.overview.codex,usage5h:{value:1,unit:'%'}}})).toThrow()); });

describe('usage window truthfulness', () => {
  const currentObservedAt = new Date().toISOString();
  const provenance = {
    source: 'codex-app-server', observedAt: currentObservedAt,
    freshness: 'fresh' as const, official: true, quality: 'observed' as const,
    connectorState: 'healthy' as const,
  };

  it('rejects unknown usage fields at every shared boundary', () => {
    expect(() => UsageProvenance.parse({ ...provenance, authorization: 'must-not-pass' })).toThrow();
    expect(() => UsageWindow.parse({ provider: 'codex', window: 'five_hour', durationMinutes: 300,
      usedPercent: 25, availability: 'observed', provenance, extra: true })).toThrow();
    expect(() => UsageHistoryEntry.parse({ provider: 'codex', window: 'five_hour', durationMinutes: 300,
      usedPercent: 25, observedAt: provenance.observedAt, extra: true })).toThrow();
    expect(() => UnifiedUsage.parse({ generatedAt: provenance.observedAt, windows: [], estimates: [],
      connectors: { codex: 'healthy', claude: 'unavailable', arbitrary: 'healthy' } })).toThrow();
  });

  it('rejects duplicate records and contradictory unavailable provenance', () => {
    const observed = { provider: 'codex' as const, window: 'five_hour' as const, durationMinutes: 300,
      usedPercent: 25, availability: 'observed' as const, provenance };
    expect(() => UnifiedUsage.parse({ generatedAt: provenance.observedAt,
      windows: [observed, observed], estimates: [], connectors: { codex: 'healthy', claude: 'unavailable' } })).toThrow();
    expect(() => UsageWindow.parse({ ...observed, usedPercent: undefined, availability: 'unavailable',
      provenance: { ...provenance, official: false, quality: 'unavailable' } })).toThrow();
  });
  it('marks old observations stale', () => {
    const window = normalizeWindow({ usedPercent: 25 }, 'codex', 'five_hour', 'codex-app-server', '2020-01-01T00:00:00Z');
    expect(window.provenance.freshness).toBe('stale');
  });

  it('rejects future and freshness/connector contradictions before numeric usage is accepted', () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    const observed = { provider: 'codex' as const, window: 'five_hour' as const,
      durationMinutes: 300, usedPercent: 25, availability: 'observed' as const, provenance };
    expect(() => UsageWindow.parse({ ...observed, provenance: { ...provenance, observedAt: future } })).toThrow();
    expect(() => UsageWindow.parse({ ...observed, provenance: { ...provenance, freshness: 'stale' } })).toThrow();
    expect(() => UsageWindow.parse({ ...observed, provenance: { ...provenance, connectorState: 'unavailable' } })).toThrow();
    expect(normalizeWindow({ usedPercent: 25 }, 'codex', 'five_hour', 'codex-app-server', future).availability).toBe('unavailable');
    expect(() => UsageHistoryEntry.parse({ provider: 'codex', window: 'five_hour', durationMinutes: 300,
      usedPercent: 25, observedAt: future })).toThrow();
  });

  it('applies the five-second clock-skew bound to observed and unavailable provenance', () => {
    const withinSkew = new Date(Date.now() + 2_000).toISOString();
    const beyondSkew = new Date(Date.now() + 60_000).toISOString();
    const observed = { provider: 'codex' as const, window: 'five_hour' as const,
      durationMinutes: 300, usedPercent: 25, availability: 'observed' as const,
      provenance: { ...provenance, observedAt: withinSkew } };
    const unavailable = { ...observed, usedPercent: undefined, availability: 'unavailable' as const,
      provenance: { ...provenance, observedAt: withinSkew, freshness: 'unknown' as const,
        official: false, quality: 'unavailable' as const, connectorState: 'unavailable' as const } };
    expect(() => UsageWindow.parse(observed)).not.toThrow();
    expect(() => UsageWindow.parse(unavailable)).not.toThrow();
    expect(() => UsageWindow.parse({ ...unavailable,
      provenance: { ...unavailable.provenance, observedAt: beyondSkew } })).toThrow();
  });

  it('drops reset details when usage is unavailable and handles invalid numeric resets', () => {
    const unavailable = normalizeWindow({ resetsAt: 1_786_777_259 }, 'codex', 'five_hour', 'codex-app-server');
    expect(unavailable).toMatchObject({ availability: 'unavailable', provenance: { official: false, quality: 'unavailable' } });
    expect(unavailable).not.toHaveProperty('resetAt');
    expect(() => normalizeWindow({ usedPercent: 25, resetsAt: Number.POSITIVE_INFINITY }, 'codex', 'five_hour', 'codex-app-server')).not.toThrow();
  });
});

const connectors = [
  {
    id: 'sparkasse', displayName: 'Sparkasse', accessMethod: 'regulated_open_banking',
    provider: 'candidate', enabled: false, requiresExplicitOptIn: true,
    risk: 'provider_confirmation_required', recommendation: 'Confirm eligibility.',
  },
  {
    id: 'paypal', displayName: 'PayPal', accessMethod: 'official_oauth',
    provider: 'official', enabled: false, requiresExplicitOptIn: true,
    risk: 'account_eligibility_required', recommendation: 'Use OAuth only.',
  },
  {
    id: 'trade_republic', displayName: 'Trade Republic', accessMethod: 'regulated_provider_pending',
    provider: 'pending', enabled: false, requiresExplicitOptIn: true,
    risk: 'experimental_only', recommendation: 'Do not use private APIs.',
  },
] as const;

describe('finance connector safety contract', () => {
  it('accepts the complete disabled opt-in catalog', () => {
    expect(FinanceConnectorCatalog.parse({ connectors }).connectors).toHaveLength(3);
  });

  it('rejects enabled, non-opt-in, and unknown connector descriptions', () => {
    expect(() => FinanceConnectorDescriptor.parse({ ...connectors[0], enabled: true })).toThrow();
    expect(() => FinanceConnectorDescriptor.parse({ ...connectors[0], requiresExplicitOptIn: false })).toThrow();
    expect(() => FinanceConnectorDescriptor.parse({ ...connectors[0], id: 'unknown' })).toThrow();
  });

  it('rejects incomplete or duplicate catalogs', () => {
    expect(() => FinanceConnectorCatalog.parse({ connectors: connectors.slice(0, 2) })).toThrow();
    expect(() => FinanceConnectorCatalog.parse({ connectors: [connectors[0], connectors[0], connectors[2]] })).toThrow();
  });
});

const unavailableFinance = {
  generatedAt: '2026-08-08T20:00:00+00:00', currency: 'EUR',
  monthlyIncome: { availability: 'unavailable', provenance: { source: 'no-authorized-finance-source', observedAt: '2026-08-08T20:00:00+00:00', freshness: 'unknown', quality: 'unavailable', connectorState: 'unavailable' } },
  fixedCosts: { availability: 'unavailable', provenance: { source: 'no-authorized-finance-source', observedAt: '2026-08-08T20:00:00+00:00', freshness: 'unknown', quality: 'unavailable', connectorState: 'unavailable' } },
  discretionaryBuffer: { availability: 'unavailable', provenance: { source: 'no-authorized-finance-source', observedAt: '2026-08-08T20:00:00+00:00', freshness: 'unknown', quality: 'unavailable', connectorState: 'unavailable' } },
  spent: { availability: 'unavailable', provenance: { source: 'no-authorized-finance-source', observedAt: '2026-08-08T20:00:00+00:00', freshness: 'unknown', quality: 'unavailable', connectorState: 'unavailable' } },
  savingsGoal: { availability: 'unavailable', provenance: { source: 'no-authorized-finance-source', observedAt: '2026-08-08T20:00:00+00:00', freshness: 'unknown', quality: 'unavailable', connectorState: 'unavailable' } },
  saved: { availability: 'unavailable', provenance: { source: 'no-authorized-finance-source', observedAt: '2026-08-08T20:00:00+00:00', freshness: 'unknown', quality: 'unavailable', connectorState: 'unavailable' } },
} as const;

describe('finance summary truthfulness', () => {
  it('represents absent finance data as unavailable without numeric values', () => {
    const parsed = FinanceSummary.parse(unavailableFinance);
    expect(parsed.monthlyIncome).not.toHaveProperty('amountCents');
  });

  it('rejects a numeric value on an unavailable metric, missing observed amounts, and extra provenance fields', () => {
    expect(() => FinanceSummary.parse({ ...unavailableFinance, spent: { ...unavailableFinance.spent, amountCents: 0 } })).toThrow();
    expect(() => FinanceSummary.parse({ ...unavailableFinance, spent: { availability: 'observed', provenance: { ...unavailableFinance.spent.provenance, quality: 'observed', connectorState: 'healthy' } } })).toThrow();
    expect(() => FinanceSummary.parse({ ...unavailableFinance, spent: { availability: 'observed', amountCents: Number.MAX_SAFE_INTEGER + 1, provenance: { ...unavailableFinance.spent.provenance, quality: 'observed', connectorState: 'healthy' } } })).toThrow();
    expect(() => FinanceSummary.parse({
      ...unavailableFinance,
      spent: { ...unavailableFinance.spent, provenance: { ...unavailableFinance.spent.provenance, accountNumber: 'must-not-pass' } },
    })).toThrow();
  });

  it('accepts at most five seconds of finance clock skew and rejects larger future values', () => {
    const withinSkew = new Date(Date.now() + 2_000).toISOString();
    const beyondSkew = new Date(Date.now() + 60_000).toISOString();
    const observed = { availability: 'observed' as const, amountCents: 100,
      provenance: { source: 'statement-import', observedAt: withinSkew, freshness: 'fresh' as const,
        quality: 'observed' as const, connectorState: 'healthy' as const } };
    expect(() => FinanceSummary.parse({ ...unavailableFinance, generatedAt: withinSkew, spent: observed })).not.toThrow();
    expect(() => FinanceSummary.parse({ ...unavailableFinance, generatedAt: withinSkew, spent: {
      ...unavailableFinance.spent, provenance: { ...unavailableFinance.spent.provenance, observedAt: withinSkew },
    } })).not.toThrow();
    expect(() => FinanceSummary.parse({ ...unavailableFinance, generatedAt: beyondSkew })).toThrow();
    expect(() => FinanceSummary.parse({ ...unavailableFinance, generatedAt: withinSkew, spent: {
      ...observed, provenance: { ...observed.provenance, observedAt: beyondSkew },
    } })).toThrow();
  });

  it('rejects future and freshness-inconsistent observed finance values', () => {
    const current = new Date().toISOString();
    const future = new Date(Date.now() + 60_000).toISOString();
    const observed = { availability: 'observed' as const, amountCents: 100,
      provenance: { source: 'statement-import', observedAt: current, freshness: 'fresh' as const,
        quality: 'observed' as const, connectorState: 'healthy' as const } };
    expect(() => FinanceSummary.parse({ ...unavailableFinance, generatedAt: current, spent: {
      ...observed, provenance: { ...observed.provenance, observedAt: future },
    } })).toThrow();
    expect(() => FinanceSummary.parse({ ...unavailableFinance, generatedAt: current, spent: {
      ...observed, provenance: { ...observed.provenance, freshness: 'stale', connectorState: 'refresh_due' },
    } })).toThrow();
  });
});
