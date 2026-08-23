import { z } from 'zod';
export * from './usage.js';
export * from './supplements.js';
export * from './nutrition.js';
export * from './nutrition-barcode.js';
export * from './nutrition-benchmark.js';
export * from './fitness-retention.js';
export * from './clipper.js';

import { ConnectorState, freshnessFromObservedAt } from './usage.js';

export const Freshness = z.enum(['fresh','stale','unknown']);
export const Quality = z.enum(['observed','estimated','partial','unavailable']);
const maximumClockSkewMs = 5_000;
const observedTimestamp = z.string().datetime({ offset: true }).refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'future observation timestamp',
);
const financeNonEmptyText = z.string().min(1).refine(
  value => value.trim().length > 0,
  'finance text must not be blank',
);
export const Provenance = z.object({ source: financeNonEmptyText, observedAt: observedTimestamp, freshness: Freshness, quality: Quality, connectorState: ConnectorState }).strict();
export type Provenance = z.infer<typeof Provenance>;
export const Metric = z.object({ value: z.number().finite(), unit: z.string().min(1), provenance: Provenance });
export const Overview = z.object({ kind: z.literal('overview'), label: z.literal('Demo data'), generatedAt: z.string().datetime({ offset: true }), codex: z.object({ status: z.string(), usage5h: Metric, usageWeek: Metric }), connectors: z.record(ConnectorState) });
export const CodexFixture = z.object({ kind: z.literal('codex'), label: z.literal('Demo data'), generatedAt: z.string().datetime({ offset: true }), session: z.object({ status: z.string(), model: z.string(), workspace: z.string(), active: z.boolean() }), usage: z.object({ fiveHour: Metric, weekly: Metric }), trend: z.array(z.object({ at: z.string().datetime({ offset: true }), value: z.number().finite(), provenance: Provenance })), estimate: z.object({ range: z.string(), confidence: z.number().min(0).max(1), explanation: z.string(), provenance: Provenance }) });
export type Overview = z.infer<typeof Overview>; export type CodexFixture = z.infer<typeof CodexFixture>;
// freshnessFromObservedAt is imported from './usage.js' (above) and re-exported via `export *` — do not redefine here.
export const fixtures = { overview: { kind:'overview', label:'Demo data', generatedAt:'2026-07-28T12:00:00+00:00', codex:{status:'active',usage5h:{value:42,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}},usageWeek:{value:31,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}}},connectors:{codex:'healthy',clipper:'unavailable',health:'unavailable',finance:'unavailable'} }, codex: { kind:'codex',label:'Demo data',generatedAt:'2026-07-28T12:00:00+00:00',session:{status:'active',model:'demo-model',workspace:'demo-workspace',active:true},usage:{fiveHour:{value:42,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}},weekly:{value:31,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}}},trend:[{at:'2026-07-28T10:00:00+00:00',value:38,provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}}],estimate:{range:'2–4 hours',confidence:.6,explanation:'Demo estimate based on fixture trend; not an official quota.',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'estimated',connectorState:'healthy'}} } };
export function parseOverview(input: unknown) { return Overview.parse(input); } export function parseCodexFixture(input: unknown) { return CodexFixture.parse(input); }

export const FinanceConnectorId = z.enum(['sparkasse_leipzig', 'revolut_personal', 'revolut_business', 'trade_republic']);
export const FinanceAccessMethod = z.enum(['regulated_open_banking', 'official_oauth', 'manual_import']);
export const FinanceConnectorRisk = z.enum(['consent_required', 'account_eligibility_required', 'manual_import_only']);
export const FinanceConnectorDescriptor = z.object({
  id: FinanceConnectorId,
  displayName: z.string().trim().min(1),
  accessMethod: FinanceAccessMethod,
  provider: z.string().trim().min(1),
  enabled: z.literal(false),
  requiresExplicitOptIn: z.literal(true),
  risk: FinanceConnectorRisk,
  recommendation: z.string().trim().min(1),
}).strict();
export type FinanceConnectorDescriptor = z.infer<typeof FinanceConnectorDescriptor>;

const requiredFinanceConnectors = new Set(FinanceConnectorId.options);
export const FinanceConnectorCatalog = z.object({
  connectors: z.array(FinanceConnectorDescriptor).length(requiredFinanceConnectors.size),
}).strict().superRefine(({ connectors }, context) => {
  const ids = new Set(connectors.map(connector => connector.id));
  if (ids.size !== connectors.length || [...requiredFinanceConnectors].some(id => !ids.has(id))) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['connectors'], message: 'complete unique finance connector catalog required' });
  }
});
export type FinanceConnectorCatalog = z.infer<typeof FinanceConnectorCatalog>;

const FinanceObservedProvenanceBase = Provenance.extend({
  freshness: z.enum(['fresh', 'stale']),
  quality: z.literal('observed'),
  connectorState: z.enum(['healthy', 'refresh_due']),
}).strict();
const FinanceObservedProvenance = FinanceObservedProvenanceBase.superRefine((value, context) => {
  const expected = freshnessFromObservedAt(value.observedAt);
  const expectedConnector = expected === 'fresh' ? 'healthy' : expected === 'stale' ? 'refresh_due' : undefined;
  if (!expectedConnector || value.freshness !== expected || value.connectorState !== expectedConnector) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'observed finance provenance is contradictory' });
  }
});
const FinanceUnavailableProvenance = Provenance.extend({
  freshness: z.literal('unknown'),
  quality: z.literal('unavailable'),
}).strict()
    .refine(value => value.connectorState !== 'healthy' && value.connectorState !== 'refresh_due', {
      message: 'unavailable finance provenance cannot have a healthy connector', path: ['connectorState'],
    });
const FinanceObservedMetric = z.object({
  availability: z.literal('observed'),
  amountCents: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  provenance: FinanceObservedProvenance,
}).strict();
const FinanceUnavailableMetric = z.object({
  availability: z.literal('unavailable'),
  provenance: FinanceUnavailableProvenance,
}).strict();
export const FinanceMetric = z.discriminatedUnion('availability', [FinanceObservedMetric, FinanceUnavailableMetric]);
export type FinanceMetric = z.infer<typeof FinanceMetric>;

const FinanceObservedAccountProvenance = FinanceObservedProvenance;
const FinanceUnavailableAccountProvenance = FinanceUnavailableProvenance;

/** Keep this wire shape in lockstep with FinanceAccountObservation in the native client. */
const FinanceAccountObservationBase = z.object({
  id: financeNonEmptyText,
  name: financeNonEmptyText,
  detail: financeNonEmptyText,
  balanceCents: z.number().int().min(-Number.MAX_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER),
  source: financeNonEmptyText,
  provenance: FinanceObservedAccountProvenance,
}).strict();
export const FinanceAccountObservation = FinanceAccountObservationBase.superRefine((value, context) => {
  if (value.source !== value.provenance.source) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['source'],
      message: 'finance account source must match its provenance source',
    });
  }
});
export type FinanceAccountObservation = z.infer<typeof FinanceAccountObservation>;

const FinanceObservedAccountSnapshot = z.object({
  availability: z.literal('observed'),
  accounts: z.array(FinanceAccountObservation).min(1),
  provenance: FinanceObservedProvenanceBase,
}).strict();
const FinanceUnavailableAccountSnapshot = z.object({
  availability: z.literal('unavailable'),
  provenance: FinanceUnavailableAccountProvenance,
}).strict();
const FinanceAccountSnapshotBase = z.discriminatedUnion('availability', [
  FinanceObservedAccountSnapshot,
  FinanceUnavailableAccountSnapshot,
]);
export const FinanceAccountSnapshot = FinanceAccountSnapshotBase.superRefine((value, context) => {
  if (value.availability !== 'observed') return;
  const rowSources = new Set(value.accounts.map(account => account.source));
  const sourceReconciles = rowSources.size === 1 && rowSources.has(value.provenance.source)
    || value.provenance.source === 'derived-account-snapshot';
  if (!sourceReconciles) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['provenance', 'source'],
      message: 'observed finance account snapshot provenance must reconcile account sources',
    });
  }
  const hasStaleAccount = value.accounts.some(account =>
    account.provenance.freshness === 'stale' || account.provenance.connectorState === 'refresh_due');
  const expectedFreshness = hasStaleAccount ? 'stale' : 'fresh';
  const expectedConnector = hasStaleAccount ? 'refresh_due' : 'healthy';
  if (value.provenance.freshness !== expectedFreshness || value.provenance.connectorState !== expectedConnector) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['provenance'],
      message: 'account snapshot freshness must represent the stalest account',
    });
  }
  const envelopeObservedAt = Date.parse(value.provenance.observedAt);
  value.accounts.forEach((account, index) => {
    if (Date.parse(account.provenance.observedAt) > envelopeObservedAt) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['accounts', index, 'provenance', 'observedAt'],
        message: 'finance account observation must not be newer than its snapshot',
      });
    }
  });
});
export type FinanceAccountSnapshot = z.infer<typeof FinanceAccountSnapshot>;

const financeDerivedTransactionSnapshotSource = 'derived-transaction-snapshot';

/**
 * A source-aware ledger row. Amounts are signed integer EUR cents: positive
 * rows are income and negative rows are spending. Keep this wire shape in
 * lockstep with `FinanceTransactionObservation` in the native client; in
 * particular, an observed row always carries its source/provenance and an
 * unavailable ledger is represented by the snapshot, never by a fake row.
 */
const FinanceTransactionObservationBase = z.object({
  id: z.string().trim().min(1),
  merchant: z.string().trim().min(1),
  title: z.string().trim().min(1),
  signedAmountCents: z.number().int().min(-Number.MAX_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER),
  timestamp: observedTimestamp,
  account: z.string().trim().min(1),
  source: z.string().trim().min(1),
  category: z.string().trim().min(1),
  provenance: FinanceObservedProvenance,
}).strict();
export const FinanceTransactionObservation = FinanceTransactionObservationBase.superRefine((value, context) => {
  if (value.source !== value.provenance.source) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['source'],
      message: 'finance transaction source must match its provenance source',
    });
  }
});
export type FinanceTransactionObservation = z.infer<typeof FinanceTransactionObservation>;

const FinanceObservedTransactionSnapshot = z.object({
  availability: z.literal('observed'),
  transactions: z.array(FinanceTransactionObservation),
  provenance: FinanceObservedProvenanceBase,
}).strict();

const FinanceUnavailableTransactionSnapshot = z.object({
  availability: z.literal('unavailable'),
  provenance: FinanceUnavailableProvenance,
}).strict();

const FinanceTransactionSnapshotBase = z.discriminatedUnion('availability', [
  FinanceObservedTransactionSnapshot,
  FinanceUnavailableTransactionSnapshot,
]);
export const FinanceTransactionSnapshot = FinanceTransactionSnapshotBase.superRefine((value, context) => {
  if (value.availability !== 'observed') return;
  if (value.transactions.length === 0) {
    const expected = freshnessFromObservedAt(value.provenance.observedAt);
    const expectedConnector = expected === 'fresh' ? 'healthy' : expected === 'stale' ? 'refresh_due' : undefined;
    if (!expectedConnector || value.provenance.freshness !== expected || value.provenance.connectorState !== expectedConnector) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['provenance'], message: 'empty observed finance transaction snapshot has contradictory provenance' });
    }
    return;
  }
  const rowSources = new Set(value.transactions.map(transaction => transaction.source));
  const sourceReconciles = rowSources.size === 0
    || (rowSources.size === 1 && rowSources.has(value.provenance.source))
    || value.provenance.source === financeDerivedTransactionSnapshotSource;
  if (!sourceReconciles) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['provenance', 'source'],
      message: 'observed finance snapshot provenance must reconcile row sources',
    });
  }
  const hasStaleRow = value.transactions.some(transaction =>
    transaction.provenance.freshness === 'stale' || transaction.provenance.connectorState === 'refresh_due');
  const expectedFreshness = hasStaleRow ? 'stale' : 'fresh';
  const expectedConnector = hasStaleRow ? 'refresh_due' : 'healthy';
  if (value.provenance.freshness !== expectedFreshness || value.provenance.connectorState !== expectedConnector) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['provenance'],
      message: 'transaction snapshot freshness must represent the stalest row',
    });
  }
  const latestRowObservation = value.transactions.reduce<string | undefined>((latest, transaction) => {
    if (!latest || Date.parse(transaction.provenance.observedAt) > Date.parse(latest)) {
      return transaction.provenance.observedAt;
    }
    return latest;
  }, undefined);
  if (latestRowObservation && Date.parse(value.provenance.observedAt) < Date.parse(latestRowObservation)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['provenance', 'observedAt'],
      message: 'observed finance snapshot timestamp must cover every row provenance timestamp',
    });
  }
});
export type FinanceTransactionSnapshot = z.infer<typeof FinanceTransactionSnapshot>;

export const FinanceSummary = z.object({
  generatedAt: z.string().datetime({ offset: true }).refine(value => Date.parse(value) <= Date.now() + maximumClockSkewMs, 'future finance generation timestamp'),
  currency: z.literal('EUR'),
  monthlyIncome: FinanceMetric,
  fixedCosts: FinanceMetric,
  discretionaryBuffer: FinanceMetric,
  spent: FinanceMetric,
  savingsGoal: FinanceMetric,
  saved: FinanceMetric,
  // Optional for summary-only connectors. Omission is intentional when no
  // source-authorized transaction history exists; an empty observed array is
  // reserved for a connector that explicitly observed an empty ledger.
  transactions: FinanceTransactionSnapshot.nullable().optional(),
  accounts: FinanceAccountSnapshot.nullable().optional(),
}).strict();
export type FinanceSummary = z.infer<typeof FinanceSummary>;
