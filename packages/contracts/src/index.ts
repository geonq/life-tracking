import { z } from 'zod';
export * from './usage.js';

import { ConnectorState } from './usage.js';

export const Freshness = z.enum(['fresh','stale','unknown']);
export const Quality = z.enum(['observed','estimated','partial','unavailable']);
const maximumClockSkewMs = 5_000;
const observedTimestamp = z.string().datetime({ offset: true }).refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'future observation timestamp',
);
export const Provenance = z.object({ source: z.string().min(1), observedAt: observedTimestamp, freshness: Freshness, quality: Quality, connectorState: ConnectorState });
export type Provenance = z.infer<typeof Provenance>;
export const Metric = z.object({ value: z.number().finite(), unit: z.string().min(1), provenance: Provenance });
export const Overview = z.object({ kind: z.literal('overview'), label: z.literal('Demo data'), generatedAt: z.string().datetime({ offset: true }), codex: z.object({ status: z.string(), usage5h: Metric, usageWeek: Metric }), connectors: z.record(ConnectorState) });
export const CodexFixture = z.object({ kind: z.literal('codex'), label: z.literal('Demo data'), generatedAt: z.string().datetime({ offset: true }), session: z.object({ status: z.string(), model: z.string(), workspace: z.string(), active: z.boolean() }), usage: z.object({ fiveHour: Metric, weekly: Metric }), trend: z.array(z.object({ at: z.string().datetime({ offset: true }), value: z.number().finite(), provenance: Provenance })), estimate: z.object({ range: z.string(), confidence: z.number().min(0).max(1), explanation: z.string(), provenance: Provenance }) });
export type Overview = z.infer<typeof Overview>; export type CodexFixture = z.infer<typeof CodexFixture>;
export function freshnessFromObservedAt(observedAt: string, now = Date.now()): 'fresh'|'stale'|'unknown' { const age = now - Date.parse(observedAt); if (!Number.isFinite(age) || age < -maximumClockSkewMs) return 'unknown'; return age <= 15 * 60_000 ? 'fresh' : 'stale'; }
export const fixtures = { overview: { kind:'overview', label:'Demo data', generatedAt:'2026-07-28T12:00:00+00:00', codex:{status:'active',usage5h:{value:42,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}},usageWeek:{value:31,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}}},connectors:{codex:'healthy',clipper:'unavailable',health:'unavailable',finance:'unavailable'} }, codex: { kind:'codex',label:'Demo data',generatedAt:'2026-07-28T12:00:00+00:00',session:{status:'active',model:'demo-model',workspace:'demo-workspace',active:true},usage:{fiveHour:{value:42,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}},weekly:{value:31,unit:'%',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}}},trend:[{at:'2026-07-28T10:00:00+00:00',value:38,provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'observed',connectorState:'healthy'}}],estimate:{range:'2–4 hours',confidence:.6,explanation:'Demo estimate based on fixture trend; not an official quota.',provenance:{source:'demo-codex-fixture',observedAt:'2026-07-28T11:55:00+00:00',freshness:'fresh',quality:'estimated',connectorState:'healthy'}} } };
export function parseOverview(input: unknown) { return Overview.parse(input); } export function parseCodexFixture(input: unknown) { return CodexFixture.parse(input); }

export const FinanceConnectorId = z.enum(['sparkasse', 'paypal', 'trade_republic']);
export const FinanceAccessMethod = z.enum(['regulated_open_banking', 'official_oauth', 'regulated_provider_pending']);
export const FinanceConnectorRisk = z.enum(['provider_confirmation_required', 'account_eligibility_required', 'experimental_only']);
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

const FinanceObservedMetric = z.object({
  availability: z.literal('observed'),
  amountCents: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  provenance: Provenance.extend({
    quality: z.literal('observed'),
    connectorState: z.enum(['healthy', 'refresh_due']),
  }).strict().superRefine((value, context) => {
    const expected = freshnessFromObservedAt(value.observedAt);
    const expectedConnector = expected === 'fresh' ? 'healthy' : expected === 'stale' ? 'refresh_due' : undefined;
    if (!expectedConnector || value.freshness !== expected || value.connectorState !== expectedConnector) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'observed finance provenance is contradictory' });
    }
  }),
}).strict();
const FinanceUnavailableMetric = z.object({
  availability: z.literal('unavailable'),
  provenance: Provenance.extend({ quality: z.literal('unavailable'), freshness: z.literal('unknown') }).strict()
    .refine(value => Date.parse(value.observedAt) <= Date.now() + maximumClockSkewMs, {
      message: 'future finance provenance timestamp', path: ['observedAt'],
    })
    .refine(value => value.connectorState !== 'healthy' && value.connectorState !== 'refresh_due', {
      message: 'unavailable finance metric cannot have a healthy connector', path: ['connectorState'],
    }),
}).strict();
export const FinanceMetric = z.discriminatedUnion('availability', [FinanceObservedMetric, FinanceUnavailableMetric]);
export type FinanceMetric = z.infer<typeof FinanceMetric>;
export const FinanceSummary = z.object({
  generatedAt: z.string().datetime({ offset: true }).refine(value => Date.parse(value) <= Date.now() + maximumClockSkewMs, 'future finance generation timestamp'),
  currency: z.literal('EUR'),
  monthlyIncome: FinanceMetric,
  fixedCosts: FinanceMetric,
  discretionaryBuffer: FinanceMetric,
  spent: FinanceMetric,
  savingsGoal: FinanceMetric,
  saved: FinanceMetric,
}).strict();
export type FinanceSummary = z.infer<typeof FinanceSummary>;
