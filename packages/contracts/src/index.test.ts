import { describe, expect, it } from 'vitest';
import { normalizeWindow, UnifiedUsage, UsageHistoryEntry, UsageProvenance, UsageWindow } from './usage.js';
import {
  ConnectorState, FinanceConnectorCatalog, FinanceConnectorDescriptor,
  FinanceAccountSnapshot, FinanceSummary, parseOverview, fixtures,
  NutritionBenchmarkFoodClass,
} from './index.js';
describe('contracts',()=>{ it('accepts truthful fixture',()=>expect(parseOverview(fixtures.overview).label).toBe('Demo data')); it('rejects invalid connector state',()=>expect(()=>ConnectorState.parse('connected')).toThrow()); it('requires provenance',()=>expect(()=>parseOverview({...fixtures.overview,codex:{...fixtures.overview.codex,usage5h:{value:1,unit:'%'}}})).toThrow()); });
describe('contract index exports', () => {
  it('re-exports the bounded nutrition benchmark contract', () => {
    expect(NutritionBenchmarkFoodClass.parse('unknown_portion')).toBe('unknown_portion');
  });
});

describe('usage window truthfulness', () => {
  const currentObservedAt = new Date().toISOString();
  const provenance = {
    source: 'codex-app-server', observedAt: currentObservedAt,
    freshness: 'fresh' as const, official: true, quality: 'observed' as const,
    connectorState: 'healthy' as const,
  };
  const connectorStates = {
    codex: 'healthy' as const,
    claude: 'unavailable' as const,
    glm: 'unavailable' as const,
    deepseek: 'unavailable' as const,
    google_ai_studio: 'unavailable' as const,
  };

  it('rejects unknown usage fields at every shared boundary', () => {
    expect(() => UsageProvenance.parse({ ...provenance, authorization: 'must-not-pass' })).toThrow();
    expect(() => UsageWindow.parse({ provider: 'codex', window: 'five_hour', durationMinutes: 300,
      usedPercent: 25, availability: 'observed', provenance, extra: true })).toThrow();
    expect(() => UsageHistoryEntry.parse({ provider: 'codex', window: 'five_hour', durationMinutes: 300,
      usedPercent: 25, observedAt: provenance.observedAt, extra: true })).toThrow();
    expect(() => UnifiedUsage.parse({ generatedAt: provenance.observedAt, windows: [], estimates: [],
      connectors: { ...connectorStates, arbitrary: 'healthy' } })).toThrow();
  });

  it('rejects duplicate records and contradictory unavailable provenance', () => {
    const observed = { provider: 'codex' as const, window: 'five_hour' as const, durationMinutes: 300,
      usedPercent: 25, availability: 'observed' as const, provenance };
    expect(() => UnifiedUsage.parse({ generatedAt: provenance.observedAt,
      windows: [observed, observed], estimates: [], connectors: connectorStates })).toThrow();
    expect(() => UsageWindow.parse({ ...observed, usedPercent: undefined, availability: 'unavailable',
      provenance: { ...provenance, official: false, quality: 'unavailable' } })).toThrow();
  });

  it('requires the complete five-provider connector catalog and preserves unavailable states', () => {
    expect(() => UnifiedUsage.parse({ generatedAt: provenance.observedAt, windows: [], estimates: [],
      connectors: { codex: 'healthy', claude: 'unavailable', glm: 'unavailable', deepseek: 'unavailable' } })).toThrow();
    expect(UnifiedUsage.parse({ generatedAt: provenance.observedAt, windows: [], estimates: [],
      connectors: connectorStates }).connectors).toEqual(connectorStates);
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
    id: 'sparkasse_leipzig', displayName: 'Sparkasse Leipzig', accessMethod: 'regulated_open_banking',
    provider: 'Enable Banking', enabled: false, requiresExplicitOptIn: true,
    risk: 'consent_required', recommendation: 'Configure the institution and complete one-time consent before enabling.',
  },
  {
    id: 'revolut_personal', displayName: 'Revolut Personal', accessMethod: 'regulated_open_banking',
    provider: 'Enable Banking', enabled: false, requiresExplicitOptIn: true,
    risk: 'consent_required', recommendation: 'Configure the institution and complete one-time consent before enabling.',
  },
  {
    id: 'revolut_business', displayName: 'Revolut Business', accessMethod: 'official_oauth',
    provider: 'Official Revolut Business API', enabled: false, requiresExplicitOptIn: true,
    risk: 'account_eligibility_required', recommendation: 'Register an eligible app and complete official OAuth before enabling.',
  },
  {
    id: 'trade_republic', displayName: 'Trade Republic', accessMethod: 'manual_import',
    provider: 'Manual CSV/PDF import', enabled: false, requiresExplicitOptIn: true,
    risk: 'manual_import_only', recommendation: 'Permanent manual CSV/PDF import only; do not use private APIs.',
  },
] as const;

describe('finance connector safety contract', () => {
  it('accepts the complete disabled opt-in catalog', () => {
    expect(FinanceConnectorCatalog.parse({ connectors }).connectors).toHaveLength(4);
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

  it('accepts an optional source-aware observed transaction snapshot', () => {
    const observedAt = new Date().toISOString();
    const row = {
      id: 'revolut-1', merchant: 'REWE', title: 'Groceries', signedAmountCents: -2450,
      timestamp: observedAt, account: 'Revolut Personal', source: 'revolut_personal', category: 'Food',
      provenance: {
        source: 'revolut_personal', observedAt, freshness: 'fresh' as const,
        quality: 'observed' as const, connectorState: 'healthy' as const,
      },
    };
    const parsed = FinanceSummary.parse({
      ...unavailableFinance,
      generatedAt: observedAt,
      transactions: {
        availability: 'observed', transactions: [row], provenance: row.provenance,
      },
    });
    expect(parsed.transactions?.availability).toBe('observed');
    if (parsed.transactions?.availability !== 'observed') throw new Error('expected observed transaction snapshot');
    expect(parsed.transactions.transactions[0]).toMatchObject({
      merchant: 'REWE', signedAmountCents: -2450, source: 'revolut_personal', category: 'Food',
    });
  });

  it('accepts an explicitly derived mixed-source transaction snapshot', () => {
    const observedAt = new Date().toISOString();
    const provenance = (source: string) => ({
      source, observedAt, freshness: 'fresh' as const,
      quality: 'observed' as const, connectorState: 'healthy' as const,
    });
    const revolutRow = {
      id: 'revolut-1', merchant: 'REWE', title: 'Groceries', signedAmountCents: -2450,
      timestamp: observedAt, account: 'Revolut Personal', source: 'revolut_personal', category: 'Food',
      provenance: provenance('revolut_personal'),
    };
    const sparkasseRow = {
      id: 'sparkasse-1', merchant: 'EDEKA', title: 'Groceries', signedAmountCents: -1000,
      timestamp: observedAt, account: 'Sparkasse', source: 'sparkasse', category: 'Food',
      provenance: provenance('sparkasse'),
    };

    const parsed = FinanceSummary.parse({
      ...unavailableFinance,
      generatedAt: observedAt,
      transactions: {
        availability: 'observed',
        transactions: [revolutRow, sparkasseRow],
        provenance: { ...provenance('derived-transaction-snapshot') },
      },
    });

    expect(parsed.transactions?.availability).toBe('observed');
  });

  it('rejects Finance row and envelope provenance mismatches', () => {
    const observedAt = new Date().toISOString();
    const row = {
      id: 'revolut-1', merchant: 'REWE', title: 'Groceries', signedAmountCents: -2450,
      timestamp: observedAt, account: 'Revolut Personal', source: 'revolut_personal', category: 'Food',
      provenance: {
        source: 'revolut_personal', observedAt, freshness: 'fresh' as const,
        quality: 'observed' as const, connectorState: 'healthy' as const,
      },
    };
    const base = { ...unavailableFinance, generatedAt: observedAt };

    expect(() => FinanceSummary.parse({
      ...base,
      transactions: {
        availability: 'observed',
        transactions: [{ ...row, source: 'sparkasse' }],
        provenance: row.provenance,
      },
    })).toThrow();

    expect(() => FinanceSummary.parse({
      ...base,
      transactions: {
        availability: 'observed',
        transactions: [row],
        provenance: { ...row.provenance, source: 'sparkasse' },
      },
    })).toThrow();

    const oldEnvelope = new Date(Date.parse(observedAt) - 1_000).toISOString();
    expect(() => FinanceSummary.parse({
      ...base,
      transactions: {
        availability: 'observed',
        transactions: [row],
        provenance: { ...row.provenance, observedAt: oldEnvelope },
      },
    })).toThrow();
  });

  it('keeps summary-only responses source honest and rejects fake transaction states', () => {
    expect(FinanceSummary.parse({ ...unavailableFinance, transactions: null }).transactions).toBeNull();
    const unavailable = {
      availability: 'unavailable',
      provenance: unavailableFinance.spent.provenance,
    };
    expect(() => FinanceSummary.parse({ ...unavailableFinance, transactions: {
      ...unavailable, transactions: [],
    } })).toThrow();
    expect(() => FinanceSummary.parse({ ...unavailableFinance, transactions: {
      availability: 'observed', transactions: [], provenance: unavailableFinance.spent.provenance,
    } })).toThrow();
  });

  it('rejects unknown transaction fields and incomplete observed provenance', () => {
    const observedAt = new Date().toISOString();
    const row = {
      id: 'revolut-1', merchant: 'REWE', title: 'Groceries', signedAmountCents: -2450,
      timestamp: observedAt, account: 'Revolut Personal', source: 'revolut_personal', category: 'Food',
      provenance: {
        source: 'revolut_personal', observedAt, freshness: 'fresh' as const,
        quality: 'observed' as const, connectorState: 'healthy' as const,
      }, extra: true,
    };
    expect(() => FinanceSummary.parse({
      ...unavailableFinance,
      generatedAt: observedAt,
      transactions: { availability: 'observed', transactions: [row], provenance: row.provenance },
    })).toThrow();
    expect(() => FinanceSummary.parse({
      ...unavailableFinance,
      generatedAt: observedAt,
      transactions: {
        availability: 'observed', transactions: [], provenance: {
          source: 'revolut_personal', observedAt, freshness: 'unknown',
          quality: 'observed', connectorState: 'healthy',
        },
      },
    })).toThrow();
  });

  it('accepts an account-only observed snapshot with opaque account fields', () => {
    const observedAt = new Date().toISOString();
    const account = {
      id: 'account-1', name: 'Girokonto', detail: 'EUR · Sparkasse Leipzig', balanceCents: 125_000,
      source: 'sparkasse_leipzig',
      provenance: {
        source: 'sparkasse_leipzig', observedAt, freshness: 'fresh' as const,
        quality: 'observed' as const, connectorState: 'healthy' as const,
      },
    };
    const parsed = FinanceSummary.parse({
      ...unavailableFinance,
      generatedAt: observedAt,
      accounts: {
        availability: 'observed', accounts: [account], provenance: account.provenance,
      },
    });
    expect(parsed.accounts?.availability).toBe('observed');
    if (parsed.accounts?.availability !== 'observed') throw new Error('expected observed account snapshot');
    expect(parsed.accounts.accounts[0]).toMatchObject({ id: 'account-1', balanceCents: 125_000 });
  });

  it('keeps unavailable account snapshots free of account rows and accepts missing consent summaries', () => {
    expect(FinanceSummary.parse(unavailableFinance).accounts).toBeUndefined();
    const unavailable = {
      availability: 'unavailable' as const,
      provenance: unavailableFinance.spent.provenance,
    };
    expect(FinanceAccountSnapshot.parse(unavailable).availability).toBe('unavailable');
    expect(() => FinanceAccountSnapshot.parse({ ...unavailable, accounts: [] })).toThrow();
  });

  it('rejects account balance overflow and source/provenance contradictions', () => {
    const observedAt = new Date().toISOString();
    const account = {
      id: 'account-1', name: 'Girokonto', detail: 'EUR', balanceCents: 100,
      source: 'sparkasse_leipzig',
      provenance: {
        source: 'sparkasse_leipzig', observedAt, freshness: 'fresh' as const,
        quality: 'observed' as const, connectorState: 'healthy' as const,
      },
    };
    const base = {
      ...unavailableFinance,
      generatedAt: observedAt,
      accounts: { availability: 'observed' as const, accounts: [account], provenance: account.provenance },
    };
    expect(() => FinanceSummary.parse({
      ...base,
      accounts: { ...base.accounts, accounts: [{ ...account, balanceCents: Number.MAX_SAFE_INTEGER + 1 }] },
    })).toThrow();
    expect(() => FinanceSummary.parse({
      ...base,
      accounts: { ...base.accounts, accounts: [{ ...account, source: 'revolut_personal' }] },
    })).toThrow();
    expect(() => FinanceSummary.parse({
      ...base,
      accounts: { ...base.accounts, provenance: { ...account.provenance, freshness: 'stale', connectorState: 'unavailable' } },
    })).toThrow();
  });

  it('accepts a representative mixed account and source-aware transaction summary', () => {
    const observedAt = new Date().toISOString();
    const provenance = {
      source: 'revolut_personal', observedAt, freshness: 'fresh' as const,
      quality: 'observed' as const, connectorState: 'healthy' as const,
    };
    const account = {
      id: 'account-2', name: 'Personal account', detail: 'EUR', balanceCents: -4_200,
      source: 'revolut_personal', provenance,
    };
    const transaction = {
      id: 'transaction-1', merchant: 'REWE', title: 'Groceries', signedAmountCents: -2_450,
      timestamp: observedAt, account: 'Personal account', source: 'revolut_personal', category: 'Food',
      provenance,
    };
    const parsed = FinanceSummary.parse({
      ...unavailableFinance,
      generatedAt: observedAt,
      accounts: { availability: 'observed', accounts: [account], provenance },
      transactions: { availability: 'observed', transactions: [transaction], provenance },
    });
    expect(parsed.accounts?.availability).toBe('observed');
    expect(parsed.transactions?.availability).toBe('observed');
  });
});
