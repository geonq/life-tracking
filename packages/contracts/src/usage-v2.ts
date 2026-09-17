import { z } from 'zod';

/**
 * Versioned, provider-neutral usage contracts.
 *
 * This module is deliberately independent from usage.ts.  The v1 schemas are
 * consumed by existing clients and must keep their closed provider/window
 * model while v2 is introduced behind an explicit schema version.
 */

const maximumIDLength = 64;
const maximumLabelLength = 80;
const maximumReasonLength = 64;
const maximumSourceLength = 128;
const maximumExplanationLength = 512;
const maximumRevision = Number.MAX_SAFE_INTEGER;
const maximumCounter = Number.MAX_SAFE_INTEGER;
const maximumConnections = 32;
const maximumWindows = 512;
const maximumObservations = 512;
const maximumEstimates = 512;
const maximumScopes = 512;
const maximumClockSkewMs = 5_000;

const idPattern = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const safeID = z.string().min(1).max(maximumIDLength).regex(idPattern, 'invalid lowercase identifier');
const noControlCharacters = (value: string): boolean => !/[\u0000-\u001f\u007f]/.test(value);
const boundedText = (maximum: number) => z.string().trim().min(1).max(maximum).refine(noControlCharacters, 'text contains a control character');
const label = boundedText(maximumLabelLength);
const reasonCode = safeID.max(maximumReasonLength);
const isoTimestamp = z.string().max(40).datetime({ offset: true });
const positiveInteger = z.number().finite().int().positive();
const revision = z.number().finite().int().nonnegative().max(maximumRevision);

export const UsageProviderID = safeID;
export type UsageProviderID = z.infer<typeof UsageProviderID>;

export const UsageConnectionID = safeID;
export type UsageConnectionID = z.infer<typeof UsageConnectionID>;

export const UsageWindowID = safeID;
export type UsageWindowID = z.infer<typeof UsageWindowID>;

export const UsageDimension = safeID;
export type UsageDimension = z.infer<typeof UsageDimension>;

const REVIEWED_PROVIDER_IDS = [
  'codex',
  'claude',
  'gemini_subscription',
  'gemini_api',
  'glm',
  'deepseek',
  'google_ai_studio',
] as const;

export const USAGE_V2_PROVIDER_IDS = Object.freeze([...REVIEWED_PROVIDER_IDS]) as typeof REVIEWED_PROVIDER_IDS;

export const BuiltInUsageProviderID = z.enum(REVIEWED_PROVIDER_IDS);
export type BuiltInUsageProviderID = z.infer<typeof BuiltInUsageProviderID>;

export const UsageProductKind = z.enum(['subscription', 'api']);
export type UsageProductKind = z.infer<typeof UsageProductKind>;

export const UsageAuthKind = z.enum(['none', 'localCLI', 'collectorSecret', 'apiKey', 'oauthPKCE']);
export type UsageAuthKind = z.infer<typeof UsageAuthKind>;

export const UsageCapability = z.enum(['officialQuota', 'localMetering', 'manualEntry']);
export type UsageCapability = z.infer<typeof UsageCapability>;

export const UsageAuthState = z.enum(['notRequired', 'disconnected', 'connected', 'reauthRequired', 'revoked']);
export type UsageAuthState = z.infer<typeof UsageAuthState>;

export const UsageAvailability = z.enum(['available', 'unavailable', 'unsupported', 'disabled']);
export type UsageAvailability = z.infer<typeof UsageAvailability>;

export const UsageEvidenceKind = z.enum(['providerReported', 'locallyMeasured', 'manual', 'estimated']);
export type UsageEvidenceKind = z.infer<typeof UsageEvidenceKind>;

type ReviewedEvidencePolicy = Readonly<{
  allowedEvidenceKinds: readonly UsageEvidenceKind[];
  officialEvidenceKinds: readonly UsageEvidenceKind[];
}>;

const reviewedProviderPolicies: Readonly<Record<BuiltInUsageProviderID, ReviewedEvidencePolicy>> = Object.freeze({
  codex: Object.freeze({
    allowedEvidenceKinds: Object.freeze(['providerReported'] as const),
    officialEvidenceKinds: Object.freeze(['providerReported'] as const),
  }),
  claude: Object.freeze({
    allowedEvidenceKinds: Object.freeze(['providerReported'] as const),
    officialEvidenceKinds: Object.freeze(['providerReported'] as const),
  }),
  gemini_subscription: Object.freeze({
    allowedEvidenceKinds: Object.freeze(['manual'] as const),
    officialEvidenceKinds: Object.freeze([] as const),
  }),
  gemini_api: Object.freeze({
    allowedEvidenceKinds: Object.freeze(['locallyMeasured', 'manual'] as const),
    officialEvidenceKinds: Object.freeze([] as const),
  }),
  glm: Object.freeze({
    allowedEvidenceKinds: Object.freeze(['manual'] as const),
    officialEvidenceKinds: Object.freeze([] as const),
  }),
  deepseek: Object.freeze({
    allowedEvidenceKinds: Object.freeze(['manual'] as const),
    officialEvidenceKinds: Object.freeze([] as const),
  }),
  google_ai_studio: Object.freeze({
    allowedEvidenceKinds: Object.freeze(['manual'] as const),
    officialEvidenceKinds: Object.freeze([] as const),
  }),
});

function getReviewedProviderPolicy(providerID: string): ReviewedEvidencePolicy | undefined {
  return Object.hasOwn(reviewedProviderPolicies, providerID)
    ? reviewedProviderPolicies[providerID as BuiltInUsageProviderID]
    : undefined;
}

export const UsageObservationScope = z.enum(['account', 'project', 'localClient']);
export type UsageObservationScope = z.infer<typeof UsageObservationScope>;

export const UsageResetPolicy = z.enum(['rolling', 'calendar', 'providerDefined']);
export type UsageResetPolicy = z.infer<typeof UsageResetPolicy>;

export const UsageUnit = z.enum(['percentage', 'counter']);
export type UsageUnit = z.infer<typeof UsageUnit>;

const uniqueAuthKinds = z.array(UsageAuthKind).min(1).max(UsageAuthKind.options.length).superRefine((values, context) => {
  if (new Set(values).size !== values.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'auth kinds must be unique' });
  }
  if (values.includes('none') && values.length > 1) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'none cannot be combined with another auth kind' });
  }
});

const uniqueCapabilities = z.array(UsageCapability).min(1).max(UsageCapability.options.length).superRefine((values, context) => {
  if (new Set(values).size !== values.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'capabilities must be unique' });
  }
});

export const UsageProviderDescriptor = z.object({
  id: UsageProviderID,
  displayName: label,
  productKind: UsageProductKind,
  adapterID: safeID,
  authKinds: uniqueAuthKinds,
  capabilities: uniqueCapabilities,
  iconToken: safeID,
}).strict();
export type UsageProviderDescriptor = z.infer<typeof UsageProviderDescriptor>;

export const UsageConnection = z.object({
  connectionID: UsageConnectionID,
  providerID: UsageProviderID,
  label,
  planLabel: label.optional(),
  enabled: z.boolean(),
  pinned: z.boolean(),
  sortOrder: z.number().finite().int().nonnegative().max(999_999),
  authState: UsageAuthState,
  availability: UsageAvailability,
  reasonCode: reasonCode.optional(),
}).strict();
export type UsageConnection = z.infer<typeof UsageConnection>;

const timezone = z.string().trim().min(1).max(maximumLabelLength).regex(/^[A-Za-z0-9_+./-]+$/, 'invalid timezone identifier');

export const UsageWindowDescriptor = z.object({
  id: UsageWindowID,
  label,
  unit: UsageUnit,
  durationMinutes: positiveInteger.max(10_000_000).optional(),
  resetPolicy: UsageResetPolicy,
  timezone: timezone.optional(),
  dimension: UsageDimension.optional(),
}).strict();
export type UsageWindowDescriptor = z.infer<typeof UsageWindowDescriptor>;

export const UsageScope = z.object({
  connectionID: UsageConnectionID,
  windowID: UsageWindowID,
  dimension: UsageDimension.optional(),
}).strict();
export type UsageScope = z.infer<typeof UsageScope>;

export function usageScopeKey(scope: UsageScope): string {
  return `${scope.connectionID}|${scope.windowID}|${scope.dimension ?? ''}`;
}

const source = boundedText(maximumSourceLength);
const observedPercent = z.number().finite().min(0).max(100);
const usedCounter = z.number().finite().nonnegative().max(maximumCounter);
const limitCounter = z.number().finite().positive().max(maximumCounter);

export const UsageObservation = z.object({
  connectionID: UsageConnectionID,
  windowID: UsageWindowID,
  dimension: UsageDimension.optional(),
  usedPercent: observedPercent.optional(),
  used: usedCounter.optional(),
  limit: limitCounter.optional(),
  resetAt: isoTimestamp.optional(),
  periodStart: isoTimestamp.optional(),
  observedAt: isoTimestamp,
  receivedAt: isoTimestamp,
  source,
  evidenceKind: UsageEvidenceKind,
  scope: UsageObservationScope,
  official: z.boolean(),
}).strict().superRefine((value, context) => {
  const hasPercentage = value.usedPercent !== undefined;
  const hasCounter = value.used !== undefined;
  if (hasPercentage === hasCounter) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'observation must use exactly one value representation' });
  }
  if (!hasCounter && value.limit !== undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['limit'], message: 'counter limit requires a counter value' });
  }
  if (hasCounter && value.limit !== undefined && value.used! > value.limit) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['used'], message: 'counter usage cannot exceed its limit' });
  }
  if ((value.evidenceKind === 'manual' || value.evidenceKind === 'estimated') && value.official) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['official'], message: 'manual and estimated observations cannot be official' });
  }
});
export type UsageObservation = z.infer<typeof UsageObservation>;

export const UsageV2Estimate = z.object({
  connectionID: UsageConnectionID,
  windowID: UsageWindowID,
  dimension: UsageDimension.optional(),
  projectedPercentAtReset: observedPercent.optional(),
  estimatedExhaustionAt: isoTimestamp.optional(),
  velocityPercentPerHour: z.number().finite().nonnegative().max(maximumCounter).optional(),
  confidence: z.enum(['low', 'medium', 'high', 'insufficient']),
  explanation: boundedText(maximumExplanationLength),
  official: z.literal(false),
}).strict();
export type UsageV2Estimate = z.infer<typeof UsageV2Estimate>;

const builtInProviderDescriptors: UsageProviderDescriptor[] = [
  {
    id: 'codex', displayName: 'Codex', productKind: 'subscription', adapterID: 'codex_cli',
    authKinds: ['localCLI'], capabilities: ['officialQuota'], iconToken: 'codex',
  },
  {
    id: 'claude', displayName: 'Claude', productKind: 'subscription', adapterID: 'claude_statusline',
    authKinds: ['collectorSecret'], capabilities: ['officialQuota'], iconToken: 'claude',
  },
  {
    id: 'gemini_subscription', displayName: 'Gemini', productKind: 'subscription', adapterID: 'gemini_subscription_manual',
    authKinds: ['none'], capabilities: ['manualEntry'], iconToken: 'gemini',
  },
  {
    id: 'gemini_api', displayName: 'Gemini API', productKind: 'api', adapterID: 'gemini_api_meter',
    authKinds: ['apiKey'], capabilities: ['localMetering', 'manualEntry'], iconToken: 'gemini',
  },
  {
    id: 'glm', displayName: 'GLM', productKind: 'api', adapterID: 'glm_manual',
    authKinds: ['apiKey'], capabilities: ['manualEntry'], iconToken: 'glm',
  },
  {
    id: 'deepseek', displayName: 'DeepSeek', productKind: 'api', adapterID: 'deepseek_manual',
    authKinds: ['apiKey'], capabilities: ['manualEntry'], iconToken: 'deepseek',
  },
  {
    id: 'google_ai_studio', displayName: 'Google AI Studio', productKind: 'api', adapterID: 'google_ai_studio_legacy',
    authKinds: ['apiKey'], capabilities: ['manualEntry'], iconToken: 'google_ai_studio',
  },
];

function hasExactProviderPolicy(actual: UsageProviderDescriptor, expected: UsageProviderDescriptor): boolean {
  return actual.id === expected.id
    && actual.displayName === expected.displayName
    && actual.productKind === expected.productKind
    && actual.adapterID === expected.adapterID
    && actual.authKinds.length === expected.authKinds.length
    && actual.authKinds.every((kind, index) => kind === expected.authKinds[index])
    && actual.capabilities.length === expected.capabilities.length
    && actual.capabilities.every((capability, index) => capability === expected.capabilities[index])
    && actual.iconToken === expected.iconToken;
}

export const UsageProviderCatalog = z.array(UsageProviderDescriptor).length(REVIEWED_PROVIDER_IDS.length).superRefine((providers, context) => {
  const counts = new Map<string, number>();
  providers.forEach((provider, index) => {
    const count = (counts.get(provider.id) ?? 0) + 1;
    counts.set(provider.id, count);
    if (count > 1) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: [index, 'id'], message: `duplicate provider id ${provider.id}` });
    }
    if (!getReviewedProviderPolicy(provider.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: [index, 'id'], message: `unknown provider id ${provider.id}` });
    }
    const expected = builtInProviderDescriptors.find(candidate => candidate.id === provider.id);
    if (expected && !hasExactProviderPolicy(provider, expected)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: [index], message: `provider policy for ${provider.id} is not approved` });
    }
  });
  REVIEWED_PROVIDER_IDS.forEach(id => {
    if (counts.get(id) !== 1) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: `catalog must contain ${id} exactly once` });
    }
  });
});
export type UsageProviderCatalog = z.infer<typeof UsageProviderCatalog>;

const reviewedProviderCatalog = UsageProviderCatalog.parse(builtInProviderDescriptors);
reviewedProviderCatalog.forEach(provider => {
  Object.freeze(provider.authKinds);
  Object.freeze(provider.capabilities);
  Object.freeze(provider);
});
export const USAGE_V2_PROVIDER_CATALOG: UsageProviderCatalog = Object.freeze(reviewedProviderCatalog) as unknown as UsageProviderCatalog;

/**
 * Unknown IDs can be displayed safely, but this descriptor is intentionally
 * not accepted by UsageProviderCatalog and has no executable or network data.
 */
export function unsupportedUsageProviderDescriptor(input: unknown): UsageProviderDescriptor {
  const id = UsageProviderID.parse(input);
  return {
    id,
    displayName: `Unsupported: ${id}`,
    productKind: 'api',
    adapterID: 'unsupported',
    authKinds: ['none'],
    capabilities: ['manualEntry'],
    iconToken: 'questionmark',
  };
}

/**
 * Official status is a policy result, never a caller-controlled assertion.
 * Only a provider-reported observation from a descriptor with the reviewed
 * officialQuota capability may carry official=true.
 */
export function isOfficialObservationAllowed(
  observation: Pick<UsageObservation, 'evidenceKind' | 'official'>,
  providerID: string,
): boolean {
  const policy = getReviewedProviderPolicy(providerID);
  if (!policy || !policy.allowedEvidenceKinds.includes(observation.evidenceKind)) return false;
  const officialAllowed = policy.officialEvidenceKinds.includes(observation.evidenceKind);
  return observation.official === officialAllowed;
}

function addDuplicateIssue(values: string[], path: (string | number)[], message: string, context: z.RefinementCtx): void {
  if (new Set(values).size !== values.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path, message });
  }
}

export const UsageV2Payload = z.object({
  schemaVersion: z.literal(2),
  revision,
  generatedAt: isoTimestamp,
  providers: UsageProviderCatalog,
  connections: z.array(UsageConnection).max(maximumConnections),
  windows: z.array(UsageWindowDescriptor).max(maximumWindows),
  observations: z.array(UsageObservation).max(maximumObservations),
  estimates: z.array(UsageV2Estimate).max(maximumEstimates),
  completeScopes: z.array(UsageScope).max(maximumScopes),
}).strict().superRefine((value, context) => {
  const connectionIDs = value.connections.map(connection => connection.connectionID);
  addDuplicateIssue(connectionIDs, ['connections'], 'connection IDs must be unique', context);
  const windowIDs = value.windows.map(window => window.id);
  addDuplicateIssue(windowIDs, ['windows'], 'window IDs must be unique', context);

  const providers = new Map(value.providers.map(provider => [provider.id, provider]));
  const connections = new Map(value.connections.map(connection => [connection.connectionID, connection]));
  const windows = new Map(value.windows.map(window => [window.id, window]));

  value.connections.forEach((connection, index) => {
    if (!providers.has(connection.providerID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['connections', index, 'providerID'], message: 'connection references an unknown provider' });
    }
  });

  const validateDimension = (dimension: UsageDimension | undefined, window: UsageWindowDescriptor, path: (string | number)[]): void => {
    if (dimension !== window.dimension) {
      context.addIssue({ code: z.ZodIssueCode.custom, path, message: 'scope dimension must match the window descriptor' });
    }
  };

  const completeScopeKeys = value.completeScopes.map(scope => usageScopeKey(scope));
  addDuplicateIssue(completeScopeKeys, ['completeScopes'], 'complete scope IDs must be unique', context);
  value.completeScopes.forEach((scope, index) => {
    if (!connections.has(scope.connectionID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['completeScopes', index, 'connectionID'], message: 'complete scope references an unknown connection' });
    }
    if (!windows.has(scope.windowID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['completeScopes', index, 'windowID'], message: 'complete scope references an unknown window' });
    }
    const window = windows.get(scope.windowID);
    if (window) validateDimension(scope.dimension, window, ['completeScopes', index, 'dimension']);
  });

  const observationKeys = new Set<string>();
  value.observations.forEach((observation, index) => {
    const connection = connections.get(observation.connectionID);
    const window = windows.get(observation.windowID);
    if (!connection) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['observations', index, 'connectionID'], message: 'observation references an unknown connection' });
    }
    if (!window) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['observations', index, 'windowID'], message: 'observation references an unknown window' });
    }
    if (window && ((window.unit === 'percentage' && observation.usedPercent === undefined)
      || (window.unit === 'counter' && observation.used === undefined)
      || (window.unit === 'percentage' && observation.used !== undefined)
      || (window.unit === 'counter' && observation.usedPercent !== undefined))) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['observations', index], message: 'observation value does not match window unit' });
    }
    if (window) validateDimension(observation.dimension, window, ['observations', index, 'dimension']);
    if (connection && !isOfficialObservationAllowed(observation, connection.providerID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['observations', index, 'official'], message: 'official flag contradicts provider evidence policy' });
    }
    const key = `${usageScopeKey(observation)}|${Date.parse(observation.observedAt)}`;
    if (observationKeys.has(key)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['observations', index], message: 'duplicate observation scope at observedAt' });
    }
    observationKeys.add(key);
  });

  const estimateKeys = new Set<string>();
  value.estimates.forEach((estimate, index) => {
    if (!connections.has(estimate.connectionID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimates', index, 'connectionID'], message: 'estimate references an unknown connection' });
    }
    if (!windows.has(estimate.windowID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimates', index, 'windowID'], message: 'estimate references an unknown window' });
    }
    const window = windows.get(estimate.windowID);
    if (window) {
      validateDimension(estimate.dimension, window, ['estimates', index, 'dimension']);
      if (window.unit === 'counter') {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimates', index], message: 'usage estimates currently support percentage windows only' });
      }
    }
    const key = usageScopeKey(estimate);
    if (estimateKeys.has(key)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimates', index], message: 'duplicate estimate scope' });
    }
    estimateKeys.add(key);
  });
});
export type UsageV2Payload = z.infer<typeof UsageV2Payload>;

/**
 * Zod validates timestamp shape, while this helper applies the live-clock
 * policy at a boundary that can be tested with a deterministic `now` value.
 * Reset and estimated-exhaustion timestamps may legitimately be in the future.
 */
export function validateUsageV2Payload(input: unknown, now = Date.now()): UsageV2Payload {
  if (!Number.isFinite(now)) throw new RangeError('now must be finite');
  const payload = UsageV2Payload.parse(input);
  const issues: z.ZodIssue[] = [];
  const validateNotFuture = (value: string, path: (string | number)[]): void => {
    if (Date.parse(value) > now + maximumClockSkewMs) {
      issues.push({ code: z.ZodIssueCode.custom, path, message: 'timestamp is too far in the future' });
    }
  };

  validateNotFuture(payload.generatedAt, ['generatedAt']);
  payload.observations.forEach((observation, index) => {
    validateNotFuture(observation.observedAt, ['observations', index, 'observedAt']);
    validateNotFuture(observation.receivedAt, ['observations', index, 'receivedAt']);
    if (observation.periodStart) validateNotFuture(observation.periodStart, ['observations', index, 'periodStart']);
  });
  if (issues.length > 0) throw new z.ZodError(issues);
  return payload;
}
