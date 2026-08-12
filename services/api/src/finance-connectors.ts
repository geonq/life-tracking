import type { FinanceConnectorDescriptor } from '@iphone-life-os/contracts';

export const financeConnectors = [
  {
    id: 'sparkasse',
    displayName: 'Sparkasse',
    accessMethod: 'regulated_open_banking',
    provider: 'GoCardless Bank Account Data',
    enabled: false,
    requiresExplicitOptIn: true,
    risk: 'consent_required',
    recommendation: 'Configure the Sparkasse institution and complete one-time GoCardless consent before enabling; keep statement import as the fallback.',
  },
  {
    id: 'revolut_personal',
    displayName: 'Revolut Personal',
    accessMethod: 'regulated_open_banking',
    provider: 'GoCardless Bank Account Data',
    enabled: false,
    requiresExplicitOptIn: true,
    risk: 'consent_required',
    recommendation: 'Configure the personal Revolut institution and complete one-time GoCardless consent before enabling; keep statement import as the fallback.',
  },
  {
    id: 'revolut_business',
    displayName: 'Revolut Business',
    accessMethod: 'official_oauth',
    provider: 'Official Revolut Business API',
    enabled: false,
    requiresExplicitOptIn: true,
    risk: 'account_eligibility_required',
    recommendation: 'Register an eligible Revolut Business app and complete official OAuth before enabling; Revolut review may delay access.',
  },
  {
    id: 'trade_republic',
    displayName: 'Trade Republic',
    accessMethod: 'manual_import',
    provider: 'Manual CSV/PDF import',
    enabled: false,
    requiresExplicitOptIn: true,
    risk: 'manual_import_only',
    recommendation: 'Permanent manual CSV/PDF import only; do not use private APIs or imply a live connector.',
  },
] as const satisfies readonly FinanceConnectorDescriptor[];
