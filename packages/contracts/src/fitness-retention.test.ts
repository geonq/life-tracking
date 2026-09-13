import { describe, expect, it } from 'vitest';
import {
  FITNESS_STORAGE_LIMITS,
  FitnessAuditRecord,
  FitnessCompactionPlan,
  FitnessCompactionRequest,
  FitnessCompactionTransition,
  FitnessRetentionSnapshot,
  FitnessStorageBreakdown,
  FitnessStorageMeasurement,
  FitnessRetentionConstants,
  advanceFitnessCompactionPlan,
  planFitnessCompaction,
} from './fitness-retention.js';

const day = 24 * 60 * 60 * 1_000;
const now = new Date().toISOString();
const ago = (days: number) => new Date(Date.now() - days * day).toISOString();
const later = new Date(Date.now() + 60_000).toISOString();

const records = [
  { id: 'meal-1', kind: 'confirmed_meal' as const, revision: 2, updatedAt: now, auditRecordID: 'audit-record-meal-1' },
  { id: 'correction-1', kind: 'correction_lineage' as const, revision: 2, updatedAt: now, auditRecordID: 'audit-record-correction-1' },
  { id: 'provenance-1', kind: 'inference_provenance' as const, revision: 2, updatedAt: now, auditRecordID: 'audit-record-provenance-1' },
];

const assets = [
  {
    id: 'photo-old', kind: 'original_photo' as const, storageClass: 'originals' as const,
    bytes: 2_000_000, observedAt: ago(100), revision: 2, updatedAt: now,
    pinned: false, exported: false, structuredRecordID: 'meal-1', correctionLineageID: 'correction-1', provenanceID: 'provenance-1', auditRecordID: 'audit-asset-photo-old',
  },
  {
    id: 'photo-pinned', kind: 'original_photo' as const, storageClass: 'originals' as const,
    bytes: 4_000_000, observedAt: ago(200), revision: 2, updatedAt: now,
    pinned: true, exported: false, structuredRecordID: 'meal-1', correctionLineageID: 'correction-1', provenanceID: 'provenance-1', auditRecordID: 'audit-asset-photo-pinned',
  },
  {
    id: 'photo-new', kind: 'original_photo' as const, storageClass: 'originals' as const,
    bytes: 1_000_000, observedAt: ago(10), revision: 2, updatedAt: now,
    pinned: false, exported: false, structuredRecordID: 'meal-1', correctionLineageID: 'correction-1', provenanceID: 'provenance-1', auditRecordID: 'audit-asset-photo-new',
  },
  {
    id: 'history-old', kind: 'detailed_history' as const, storageClass: 'detailed_history' as const,
    bytes: 3_000_000, observedAt: ago(400), revision: 2, updatedAt: now,
    pinned: false, exported: false, dailyRollupID: 'rollup-day-1', weeklyRollupID: 'rollup-week-1', auditRecordID: 'audit-asset-history-old',
  },
];

const auditRecords = [
  ...records.map(record => ({ id: record.auditRecordID, entityKind: 'record' as const, entityID: record.id, state: 'preserved' as const, revision: 2, recordedAt: now })),
  ...assets.map(asset => ({ id: asset.auditRecordID, entityKind: 'asset' as const, entityID: asset.id, state: 'active' as const, revision: 2, recordedAt: now })),
  { id: 'audit-rollup-day-1', entityKind: 'rollup' as const, entityID: 'rollup-day-1', state: 'preserved' as const, revision: 2, recordedAt: now },
  { id: 'audit-rollup-week-1', entityKind: 'rollup' as const, entityID: 'rollup-week-1', state: 'preserved' as const, revision: 2, recordedAt: now },
];

const rollups = [
  {
    id: 'rollup-day-1', granularity: 'daily' as const, periodStart: ago(401), periodEnd: ago(400),
    sourceAssetIDs: ['history-old'], min: 1, max: 10, mean: 5, sampleCount: 10,
    sourceCoverage: 'complete' as const, quality: 'observed' as const, pinnedRawIntervalIDs: [], auditRecordID: 'audit-rollup-day-1', revision: 2, updatedAt: now,
  },
  {
    id: 'rollup-week-1', granularity: 'weekly' as const, periodStart: ago(407), periodEnd: ago(400),
    sourceAssetIDs: ['history-old'], min: 1, max: 10, mean: 5, sampleCount: 10,
    sourceCoverage: 'complete' as const, quality: 'observed' as const, pinnedRawIntervalIDs: [], auditRecordID: 'audit-rollup-week-1', revision: 2, updatedAt: now,
  },
];

const storage = (totalBytes = 30_000_000) => ({
  measuredAt: now,
  revision: 2,
  measurements: [
    { id: 'measurement-originals', storageClass: 'originals' as const, bytes: totalBytes - 1, measuredAt: now, revision: 2 },
    { id: 'measurement-history', storageClass: 'detailed_history' as const, bytes: 1, measuredAt: now, revision: 2 },
  ],
  totalBytes,
});

const snapshot = (overrides: Record<string, unknown> = {}) => ({
  schemaVersion: 1 as const,
  revision: 2,
  observedAt: now,
  storage: storage(),
  retentionPolicy: {
    schemaVersion: 1 as const,
    originalRetentionDays: 90 as const,
    detailedHistoryRetentionDays: 365 as const,
    allowOriginalCompaction: true,
    allowDetailedHistoryCompaction: true,
  },
  assets,
  records,
  rollups,
  auditRecords,
  ...overrides,
});

const request = (overrides: Record<string, unknown> = {}) => ({ ...snapshot(), planID: 'plan-1', ...overrides });

describe('Fitness storage and retention contracts', () => {
  it('accepts a strict linked snapshot and reports exact storage totals', () => {
    expect(FitnessStorageMeasurement.parse(storage().measurements[0]).storageClass).toBe('originals');
    expect(FitnessStorageBreakdown.parse(storage()).totalBytes).toBe(30_000_000);
    expect(FitnessRetentionSnapshot.parse(snapshot()).assets).toHaveLength(4);
  });

  it('plans due originals/history while preserving protected and recent assets', () => {
    const plan = planFitnessCompaction(request());
    expect(plan.storagePressure).toBe('normal');
    expect(plan.ingestionMode).toBe('persistent_photo_allowed');
    expect(plan.operations.map(operation => operation.sourceAssetID)).toEqual(['photo-old', 'history-old']);
    expect(plan.estimatedReclaimableBytes).toBe(4_488_000);
    expect(plan.protectedBytes).toBe(4_000_000);
    expect(plan.execution).toBe('plan_only_no_deletion');
    expect(plan.operations[0]).toMatchObject({
      sourceDisposition: 'retain_until_commit',
      sourceRemoval: { action: 'remove_source_after_validated_commit', requiresExplicitPolicy: true },
      transactionSteps: ['write_replacement', 'validate_replacement', 'verify_export_and_provenance', 'remove_source_after_commit'],
    });
    expect(plan.preserve.structuredRecordIDs).toEqual(['meal-1']);
    expect(plan.preserve.dailyRollupIDs).toEqual(['rollup-day-1']);
    expect(plan.preserve.weeklyRollupIDs).toEqual(['rollup-week-1']);
  });

  it('applies 8/9/10 GB thresholds and accounts for a requested photo before ingestion', () => {
    const at = (totalBytes: number, requestedPhotoBytes?: number) => planFitnessCompaction(request({
      storage: storage(totalBytes),
      ...(requestedPhotoBytes === undefined ? {} : { requestedPhotoBytes }),
    }));
    expect(at(FITNESS_STORAGE_LIMITS.warningBytes)).toMatchObject({ storagePressure: 'warning', ingestionMode: 'persistent_photo_allowed' });
    expect(at(FITNESS_STORAGE_LIMITS.aggressiveCompactionBytes)).toMatchObject({ storagePressure: 'aggressive_compaction', ingestionMode: 'structured_only_transient_photo' });
    expect(at(FITNESS_STORAGE_LIMITS.hardCapBytes)).toMatchObject({ storagePressure: 'hard_ingestion_gate', ingestionMode: 'manual_only_no_photo_retention' });
    expect(at(FITNESS_STORAGE_LIMITS.aggressiveCompactionBytes - 1, 1)).toMatchObject({ storagePressure: 'aggressive_compaction', ingestionMode: 'structured_only_transient_photo' });
    expect(at(FITNESS_STORAGE_LIMITS.hardCapBytes - 1, 1)).toMatchObject({ storagePressure: 'hard_ingestion_gate', ingestionMode: 'manual_only_no_photo_retention' });
  });

  it('does not schedule retention when the user policy disallows a class', () => {
    const plan = planFitnessCompaction(request({ retentionPolicy: { ...snapshot().retentionPolicy, allowOriginalCompaction: false } }));
    expect(plan.operations.map(operation => operation.sourceAssetID)).toEqual(['history-old']);
  });

  it('rejects unknown fields, duplicates, dangling links, and contradictory rollups', () => {
    expect(() => FitnessStorageMeasurement.parse({ ...storage().measurements[0], unexpected: true })).toThrow();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({ storage: {
      ...storage(), measurements: [storage().measurements[0], storage().measurements[0]], totalBytes: storage().measurements[0].bytes * 2,
    } }))).toThrow();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({ assets: [assets[0], assets[0], ...assets.slice(1)] }))).toThrow();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({ assets: [{ ...assets[3], dailyRollupID: 'missing-rollup' }] }))).toThrow();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({ rollups: [{ ...rollups[0], sourceAssetIDs: ['photo-old'] }, rollups[1]] }))).toThrow();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({ rollups: [{ ...rollups[0], sourceCoverage: 'complete', quality: 'unavailable' }, rollups[1]] }))).toThrow();
  });

  it('rejects future timestamps beyond five seconds and unsafe sizes/revisions', () => {
    expect(() => FitnessRetentionSnapshot.parse(snapshot({ observedAt: later }))).toThrow();
    expect(() => FitnessStorageMeasurement.parse({ ...storage().measurements[0], measuredAt: later })).toThrow();
    expect(() => FitnessStorageMeasurement.parse({ ...storage().measurements[0], bytes: FitnessRetentionConstants.maximumStorageBytes + 1 })).toThrow();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({ revision: Number.MAX_SAFE_INTEGER + 1 }))).toThrow();
  });

  it('allows append-only audit history and tombstones for entities no longer present', () => {
    const historicalAudit = { id: 'audit-asset-photo-old-history', entityKind: 'asset' as const, entityID: 'photo-old', state: 'preserved' as const, revision: 1, recordedAt: ago(99) };
    const tombstone = { id: 'audit-asset-removed', entityKind: 'asset' as const, entityID: 'photo-removed', state: 'deleted_tombstone' as const, revision: 3, recordedAt: ago(1) };
    expect(FitnessRetentionSnapshot.parse(snapshot({ auditRecords: [...auditRecords, historicalAudit, tombstone] })).auditRecords).toHaveLength(auditRecords.length + 2);
  });

  it('can describe a breached diagnostic measurement above the 10 GB policy cap', () => {
    const breached = FITNESS_STORAGE_LIMITS.hardCapBytes + 1;
    expect(FitnessStorageMeasurement.parse({ id: 'measurement-breached', storageClass: 'originals', bytes: breached, measuredAt: now, revision: 2 }).bytes).toBe(breached);
  });

  it('rejects nested timestamps that postdate the snapshot chronology', () => {
    const snapshotTime = new Date(Date.now() - 60_000).toISOString();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({
      observedAt: snapshotTime,
      storage: { ...storage(), measuredAt: now },
    }))).toThrow();
    expect(() => FitnessRetentionSnapshot.parse(snapshot({
      observedAt: snapshotTime,
      assets: [{ ...assets[0], observedAt: now }, ...assets.slice(1)],
    }))).toThrow();
  });
});

describe('Fitness compaction transaction state machine', () => {
  it('requires ordered validation proofs and never changes source-removal semantics', () => {
    const plan = planFitnessCompaction(request());
    const staging = advanceFitnessCompactionPlan(plan, {
      transitionID: 'transition-begin', planID: plan.planID, expectedRevision: plan.revision, event: 'begin', occurredAt: now,
    });
    expect(staging.status).toBe('staging');
    const operationIDs = staging.operations.map(operation => operation.operationID);
    const validated = advanceFitnessCompactionPlan(staging, {
      transitionID: 'transition-validate', planID: plan.planID, expectedRevision: staging.revision, event: 'validate', occurredAt: now,
      validatedOperationIDs: operationIDs, exportVerifiedOperationIDs: operationIDs,
    });
    expect(validated.status).toBe('validated');
    const committed = advanceFitnessCompactionPlan(validated, {
      transitionID: 'transition-commit', planID: plan.planID, expectedRevision: validated.revision, event: 'commit', occurredAt: now,
    });
    expect(committed.status).toBe('committed');
    expect(committed.execution).toBe('plan_only_no_deletion');
    expect(committed.operations.every(operation => operation.sourceDisposition === 'retain_until_commit')).toBe(true);
  });

  it('keeps a failed transaction resumable and rejects stale/contradictory transitions', () => {
    const plan = planFitnessCompaction(request());
    const staging = advanceFitnessCompactionPlan(plan, {
      transitionID: 'transition-begin', planID: plan.planID, expectedRevision: plan.revision, event: 'begin', occurredAt: now,
    });
    const failed = advanceFitnessCompactionPlan(staging, {
      transitionID: 'transition-fail', planID: plan.planID, expectedRevision: staging.revision, event: 'fail', occurredAt: now, failureReason: 'thumbnail validation failed',
    });
    expect(failed.status).toBe('failed');
    expect(failed.operations.every(operation => operation.sourceDisposition === 'retain_until_commit')).toBe(true);
    const retry = advanceFitnessCompactionPlan(failed, {
      transitionID: 'transition-retry', planID: plan.planID, expectedRevision: failed.revision, event: 'retry', occurredAt: now,
    });
    expect(retry.status).toBe('staging');
    expect(() => advanceFitnessCompactionPlan(plan, {
      transitionID: 'stale', planID: plan.planID, expectedRevision: plan.revision - 1, event: 'begin', occurredAt: now,
    })).toThrow();
    expect(() => advanceFitnessCompactionPlan(plan, {
      transitionID: 'direct-commit', planID: plan.planID, expectedRevision: plan.revision, event: 'commit', occurredAt: now,
    })).toThrow();
    expect(() => FitnessCompactionTransition.parse({
      transitionID: 'bad-transition', planID: plan.planID, expectedRevision: plan.revision, event: 'begin', occurredAt: now, failureReason: 'contradictory',
    })).toThrow();
    expect(() => FitnessCompactionPlan.parse({ ...plan, status: 'committed', committedAt: now })).toThrow();
    expect(() => advanceFitnessCompactionPlan(staging, {
      transitionID: 'too-early', planID: plan.planID, expectedRevision: staging.revision, event: 'fail', occurredAt: new Date(Date.parse(staging.updatedAt) - 1).toISOString(), failureReason: 'out of order',
    })).toThrow();
  });
});
