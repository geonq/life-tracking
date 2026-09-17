import { describe, expect, it } from 'vitest';
import {
  BuiltInUsageProviderID,
  isOfficialObservationAllowed,
  unsupportedUsageProviderDescriptor,
  UsageProviderCatalog,
  UsageProviderID,
  UsageV2Payload,
  USAGE_V2_PROVIDER_CATALOG,
  USAGE_V2_PROVIDER_IDS,
  validateUsageV2Payload,
} from './usage-v2.js';

const generatedAt = '2026-09-17T11:59:00+00:00';
const observedAt = '2026-09-17T11:50:00+00:00';
const receivedAt = '2026-09-17T11:51:00+00:00';

type EstimateFixture = {
  connectionID: string;
  windowID: string;
  dimension?: string;
  projectedPercentAtReset?: number;
  estimatedExhaustionAt?: string;
  velocityPercentPerHour?: number;
  confidence: 'low' | 'medium' | 'high' | 'insufficient';
  explanation: string;
  official: false;
};

function payloadFixture() {
  return {
    schemaVersion: 2 as const,
    revision: 7,
    generatedAt,
    providers: USAGE_V2_PROVIDER_CATALOG,
    connections: [
      {
        connectionID: 'gemini-pro', providerID: 'gemini_subscription', label: 'Gemini Pro', planLabel: 'Google AI Pro',
        enabled: true, pinned: true, sortOrder: 0, authState: 'notRequired' as const, availability: 'available' as const,
      },
      {
        connectionID: 'gemini-api-project', providerID: 'gemini_api', label: 'Gemini API project',
        enabled: true, pinned: false, sortOrder: 1, authState: 'connected' as const, availability: 'available' as const,
      },
    ],
    windows: [
      {
        id: 'subscription-usage', label: 'Subscription usage', unit: 'percentage' as const,
        durationMinutes: 300, resetPolicy: 'providerDefined' as const,
      },
      {
        id: 'api-requests', label: 'API requests', unit: 'counter' as const,
        resetPolicy: 'providerDefined' as const, dimension: 'requests',
      },
    ],
    observations: [
      {
        connectionID: 'gemini-pro', windowID: 'subscription-usage', usedPercent: 25,
        observedAt, receivedAt, source: 'manual', evidenceKind: 'manual' as const,
        scope: 'account' as const, official: false,
      },
      {
        connectionID: 'gemini-api-project', windowID: 'api-requests', dimension: 'requests', used: 100, limit: 1_000,
        observedAt: '2026-09-17T11:52:00+00:00', receivedAt, source: 'gemini_api_meter',
        evidenceKind: 'locallyMeasured' as const, scope: 'project' as const, official: false,
      },
    ],
    estimates: [] as EstimateFixture[],
    completeScopes: [
      { connectionID: 'gemini-pro', windowID: 'subscription-usage' },
      { connectionID: 'gemini-api-project', windowID: 'api-requests', dimension: 'requests' },
    ],
  };
}

describe('usage v2 provider registry', () => {
  it('contains each built-in provider exactly once with the Gemini policies', () => {
    const catalog = UsageProviderCatalog.parse(USAGE_V2_PROVIDER_CATALOG);
    expect(catalog.map(provider => provider.id)).toEqual([...USAGE_V2_PROVIDER_IDS]);
    expect(BuiltInUsageProviderID.options).toEqual([...USAGE_V2_PROVIDER_IDS]);

    const geminiSubscription = catalog.find(provider => provider.id === 'gemini_subscription');
    const geminiAPI = catalog.find(provider => provider.id === 'gemini_api');
    const claude = catalog.find(provider => provider.id === 'claude');
    const codex = catalog.find(provider => provider.id === 'codex');
    expect(geminiSubscription?.capabilities).toEqual(['manualEntry']);
    expect(geminiSubscription?.capabilities).not.toContain('officialQuota');
    expect(geminiAPI?.capabilities).toEqual(['localMetering', 'manualEntry']);
    expect(geminiAPI?.productKind).toBe('api');
    expect(claude?.capabilities).toContain('officialQuota');
    expect(codex?.capabilities).toContain('officialQuota');
  });

  it('rejects malformed and unknown IDs while providing a safe unsupported descriptor', () => {
    expect(UsageProviderID.safeParse('Gemini').success).toBe(false);
    expect(UsageProviderID.safeParse('-bad').success).toBe(false);
    expect(UsageProviderID.safeParse('a'.repeat(65)).success).toBe(false);
    expect(UsageProviderCatalog.safeParse(USAGE_V2_PROVIDER_CATALOG.map((provider, index) => (
      index === 0 ? { ...provider, id: 'future_provider' } : provider
    ))).success).toBe(false);
    expect(UsageProviderCatalog.safeParse(USAGE_V2_PROVIDER_CATALOG.map((provider, index) => (
      index === 1 ? { ...provider, id: 'codex' } : provider
    ))).success).toBe(false);
    expect(UsageProviderCatalog.safeParse(USAGE_V2_PROVIDER_CATALOG.map(provider => (
      provider.id === 'gemini_subscription' ? { ...provider, capabilities: ['officialQuota'] } : provider
    ))).success).toBe(false);

    expect(unsupportedUsageProviderDescriptor('future_provider')).toMatchObject({
      id: 'future_provider', adapterID: 'unsupported', authKinds: ['none'], capabilities: ['manualEntry'],
    });
  });

  it('accepts manual Gemini subscription and locally measured Gemini API observations', () => {
    const result = UsageV2Payload.safeParse(payloadFixture());
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.observations.map(observation => observation.connectionID)).toEqual([
        'gemini-pro', 'gemini-api-project',
      ]);
    }
  });

  it('derives official status from provider capability and evidence kind', () => {
    const manualGemini = { evidenceKind: 'manual' as const, official: false };
    const spoofedGemini = { evidenceKind: 'manual' as const, official: true };
    const officialCodex = { evidenceKind: 'providerReported' as const, official: true };
    const spoofedLocalCodex = { evidenceKind: 'locallyMeasured' as const, official: true };
    const gemini = USAGE_V2_PROVIDER_CATALOG.find(provider => provider.id === 'gemini_subscription')!;
    const codex = USAGE_V2_PROVIDER_CATALOG.find(provider => provider.id === 'codex')!;

    expect(isOfficialObservationAllowed(manualGemini, gemini.id)).toBe(true);
    expect(isOfficialObservationAllowed(spoofedGemini, gemini.id)).toBe(false);
    expect(isOfficialObservationAllowed(officialCodex, codex.id)).toBe(true);
    expect(isOfficialObservationAllowed(spoofedLocalCodex, codex.id)).toBe(false);
    expect(isOfficialObservationAllowed({ evidenceKind: 'providerReported', official: false }, 'gemini_api')).toBe(false);
    expect(isOfficialObservationAllowed({ evidenceKind: 'locallyMeasured', official: true }, 'gemini_api')).toBe(false);
    expect(isOfficialObservationAllowed({ evidenceKind: 'manual', official: false }, 'unknown_provider')).toBe(false);

    const invalidManual = payloadFixture();
    Object.assign(invalidManual.observations[0], { official: true });
    expect(UsageV2Payload.safeParse(invalidManual).success).toBe(false);

    const invalidLocal = payloadFixture();
    Object.assign(invalidLocal.observations[1], { official: true });
    expect(UsageV2Payload.safeParse(invalidLocal).success).toBe(false);

    const invalidSubscriptionEvidence = payloadFixture();
    Object.assign(invalidSubscriptionEvidence.observations[0], { evidenceKind: 'locallyMeasured' });
    expect(UsageV2Payload.safeParse(invalidSubscriptionEvidence).success).toBe(false);

    const invalidSubscriptionProviderReport = payloadFixture();
    Object.assign(invalidSubscriptionProviderReport.observations[0], { evidenceKind: 'providerReported', official: true });
    expect(UsageV2Payload.safeParse(invalidSubscriptionProviderReport).success).toBe(false);

    const invalidGeminiAPIProviderReport = payloadFixture();
    Object.assign(invalidGeminiAPIProviderReport.observations[1], { evidenceKind: 'providerReported', official: true });
    expect(UsageV2Payload.safeParse(invalidGeminiAPIProviderReport).success).toBe(false);
  });

  it('rejects duplicate scopes, invalid bounds, and cross-reference failures', () => {
    const duplicateObservation = payloadFixture();
    duplicateObservation.observations.push({ ...duplicateObservation.observations[0] });
    expect(UsageV2Payload.safeParse(duplicateObservation).success).toBe(false);

    const duplicateCompleteScope = payloadFixture();
    duplicateCompleteScope.completeScopes.push({ ...duplicateCompleteScope.completeScopes[0] });
    expect(UsageV2Payload.safeParse(duplicateCompleteScope).success).toBe(false);

    const badReferences = payloadFixture();
    badReferences.observations[0] = { ...badReferences.observations[0], connectionID: 'missing-connection' };
    expect(UsageV2Payload.safeParse(badReferences).success).toBe(false);

    const unknownProviderWithoutData = payloadFixture();
    unknownProviderWithoutData.connections.push({ ...unknownProviderWithoutData.connections[0], connectionID: 'unreviewed', providerID: 'unreviewed_provider' });
    expect(UsageV2Payload.safeParse(unknownProviderWithoutData).success).toBe(false);

    const unknownProviderObservation = payloadFixture();
    Object.assign(unknownProviderObservation.connections[1], { providerID: 'unreviewed_provider' });
    Object.assign(unknownProviderObservation.observations[1], { evidenceKind: 'manual', official: false });
    expect(UsageV2Payload.safeParse(unknownProviderObservation).success).toBe(false);

    const unknownProviderEstimate = payloadFixture();
    Object.assign(unknownProviderEstimate.connections[1], { providerID: 'unreviewed_provider' });
    unknownProviderEstimate.estimates.push({
      connectionID: 'gemini-api-project', windowID: 'subscription-usage', projectedPercentAtReset: 50,
      confidence: 'medium', explanation: 'unsupported provider', official: false,
    });
    expect(UsageV2Payload.safeParse(unknownProviderEstimate).success).toBe(false);

    const badUnit = payloadFixture();
    Object.assign(badUnit.observations[0], { usedPercent: undefined, used: 1 });
    expect(UsageV2Payload.safeParse(badUnit).success).toBe(false);

    const badCounter = payloadFixture();
    Object.assign(badCounter.observations[1], { used: 1_001 });
    expect(UsageV2Payload.safeParse(badCounter).success).toBe(false);

    const missingDimension = payloadFixture();
    Object.assign(missingDimension.observations[1], { dimension: undefined });
    expect(UsageV2Payload.safeParse(missingDimension).success).toBe(false);

    const inventedDimension = payloadFixture();
    Object.assign(inventedDimension.observations[0], { dimension: 'made_up' });
    expect(UsageV2Payload.safeParse(inventedDimension).success).toBe(false);

    const wrongCompleteScopeDimension = payloadFixture();
    Object.assign(wrongCompleteScopeDimension.completeScopes[1], { dimension: 'wrong_dimension' });
    expect(UsageV2Payload.safeParse(wrongCompleteScopeDimension).success).toBe(false);

    const percentageEstimate = payloadFixture();
    percentageEstimate.estimates.push({
      connectionID: 'gemini-pro', windowID: 'subscription-usage', projectedPercentAtReset: 50,
      confidence: 'medium', explanation: 'manual projection', official: false,
    });
    expect(UsageV2Payload.safeParse(percentageEstimate).success).toBe(true);

    const wrongEstimateDimension = payloadFixture();
    wrongEstimateDimension.estimates.push({
      connectionID: 'gemini-api-project', windowID: 'api-requests', dimension: 'wrong_dimension',
      confidence: 'medium', explanation: 'dimension mismatch', official: false,
    });
    expect(UsageV2Payload.safeParse(wrongEstimateDimension).success).toBe(false);

    const spoofedEstimate = payloadFixture();
    spoofedEstimate.estimates.push({
      connectionID: 'gemini-pro', windowID: 'subscription-usage', projectedPercentAtReset: 50,
      confidence: 'medium', explanation: 'estimates are never official', official: false,
    });
    Object.assign(spoofedEstimate.estimates[0], { official: true });
    expect(UsageV2Payload.safeParse(spoofedEstimate).success).toBe(false);

    const counterEstimate = payloadFixture();
    counterEstimate.estimates.push({
      connectionID: 'gemini-api-project', windowID: 'api-requests', dimension: 'requests', projectedPercentAtReset: 50,
      confidence: 'medium', explanation: 'counter projection is not percentage compatible', official: false,
    });
    expect(UsageV2Payload.safeParse(counterEstimate).success).toBe(false);

    const badLabel = payloadFixture();
    badLabel.connections[0] = { ...badLabel.connections[0], label: 'x'.repeat(81) };
    expect(UsageV2Payload.safeParse(badLabel).success).toBe(false);

    const tooManyConnections = payloadFixture();
    tooManyConnections.connections = Array.from({ length: 33 }, (_, index) => ({
      ...payloadFixture().connections[0], connectionID: `gemini-pro-${index}`,
    }));
    expect(UsageV2Payload.safeParse(tooManyConnections).success).toBe(false);

    expect(Object.isFrozen(USAGE_V2_PROVIDER_IDS)).toBe(true);
    expect(Object.isFrozen(USAGE_V2_PROVIDER_CATALOG)).toBe(true);
    expect(Object.isFrozen(USAGE_V2_PROVIDER_CATALOG[0].authKinds)).toBe(true);
    expect(Object.isFrozen(USAGE_V2_PROVIDER_CATALOG[0].capabilities)).toBe(true);
  });

  it('applies the live clock policy through the exported runtime validator', () => {
    const future = payloadFixture();
    future.generatedAt = '2026-09-17T12:00:06+00:00';
    expect(UsageV2Payload.safeParse(future).success).toBe(true);
    expect(() => validateUsageV2Payload(future, Date.parse('2026-09-17T12:00:00+00:00'))).toThrow(/future/);

    const valid = payloadFixture();
    expect(() => validateUsageV2Payload(valid, Date.parse('2026-09-17T12:00:00+00:00'))).not.toThrow();
  });
});
