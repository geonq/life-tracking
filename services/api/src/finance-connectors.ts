import type { FinanceConnectorDescriptor } from '@iphone-life-os/contracts';

export const financeConnectors = [
  {
    id: 'sparkasse',
    displayName: 'Sparkasse',
    accessMethod: 'regulated_open_banking',
    provider: 'Enable Banking candidate; finAPI fallback',
    enabled: false,
    requiresExplicitOptIn: true,
    risk: 'provider_confirmation_required',
    recommendation: 'Confirm the exact Sparkasse institution and restricted-production eligibility before OAuth consent.',
  },
  {
    id: 'paypal',
    displayName: 'PayPal',
    accessMethod: 'official_oauth',
    provider: 'PayPal Transaction Search API',
    enabled: false,
    requiresExplicitOptIn: true,
    risk: 'account_eligibility_required',
    recommendation: 'Use official OAuth only; fall back to statement import if this account cannot access transaction history.',
  },
  {
    id: 'trade_republic',
    displayName: 'Trade Republic',
    accessMethod: 'regulated_provider_pending',
    provider: 'Regulated PSD2 provider or official route',
    enabled: false,
    requiresExplicitOptIn: true,
    risk: 'experimental_only',
    recommendation: 'Keep pytr out of production because it uses an unsupported private API and handles PIN/SMS device authentication.',
  },
] as const satisfies readonly FinanceConnectorDescriptor[];
