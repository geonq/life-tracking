import { z } from 'zod';

/**
 * Fitness retention is a contract and planning boundary only.  Nothing in
 * this module opens a store, removes a file, or claims that a planned removal
 * has happened.
 */

const maximumClockSkewMs = 5_000;
const maximumRevision = Number.MAX_SAFE_INTEGER;
const maximumIDLength = 128;
// The policy cap is 10 GiB, but diagnostics must still be able to describe a
// breached store.  Keep malformed measurements bounded independently.
const maximumStorageBytes = 1_024 * 1024 * 1024 * 1024;
const maximumPhotoBytesPerRequest = 20 * 1024 * 1024;
const maximumMeasurements = 32;
const maximumAssets = 100_000;
const maximumRecords = 100_000;
const maximumRollups = 100_000;
const maximumAuditRecords = 300_000;
const maximumSourceAssetsPerRollup = 100_000;
const maximumMetricValue = 1_000_000_000_000;
const targetDerivativeBytes = 500 * 1024;
const dayMilliseconds = 24 * 60 * 60 * 1_000;

export const FITNESS_STORAGE_LIMITS = {
  warningBytes: 8 * 1024 * 1024 * 1024,
  aggressiveCompactionBytes: 9 * 1024 * 1024 * 1024,
  hardCapBytes: 10 * 1024 * 1024 * 1024,
  targetDerivativeBytes,
  originalRetentionDays: 90,
  detailedHistoryRetentionDays: 365,
} as const;

export const FitnessStorageClass = z.enum([
  'originals',
  'sanitized_images',
  'derivatives',
  'structured_records',
  'detailed_history',
  'database_pages',
  'indexes',
  'write_ahead_logs',
  'temporary_files',
  'thumbnails',
  'caches',
  'diagnostic_metadata',
  'rolling_backups',
]);
export type FitnessStorageClass = z.infer<typeof FitnessStorageClass>;

export const StorageClass = FitnessStorageClass;
export type StorageClass = FitnessStorageClass;

const safeIDPattern = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})$/;
const boundedID = z.string().min(1).max(maximumIDLength).regex(safeIDPattern, 'unsafe fitness identifier');
export const FitnessRetentionID = boundedID;
export type FitnessRetentionID = z.infer<typeof FitnessRetentionID>;

const timestamp = z.string().max(40).datetime({ offset: true });
const observedTimestamp = timestamp.refine(
  value => Date.parse(value) <= Date.now() + maximumClockSkewMs,
  'timestamp is too far in the future',
);
const revision = z.number().finite().int().nonnegative().max(maximumRevision);
const bytes = z.number().finite().int().nonnegative().max(maximumStorageBytes);
const metric = z.number().finite().min(-maximumMetricValue).max(maximumMetricValue);
const boundedText = (maximum: number) => z.string().trim().min(1).max(maximum);

const uniqueIDs = (maximum: number, minimum = 0) => z.array(boundedID).min(minimum).max(maximum).superRefine((values, context) => {
  if (new Set(values).size !== values.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'array entries must be unique' });
  }
});

export const FitnessStorageMeasurement = z.object({
  id: boundedID,
  storageClass: FitnessStorageClass,
  bytes,
  measuredAt: observedTimestamp,
  revision,
}).strict();
export type FitnessStorageMeasurement = z.infer<typeof FitnessStorageMeasurement>;

export const FitnessStorageBreakdown = z.object({
  measuredAt: observedTimestamp,
  revision,
  measurements: z.array(FitnessStorageMeasurement).min(1).max(maximumMeasurements),
  totalBytes: z.number().finite().int().nonnegative().max(maximumStorageBytes * maximumMeasurements),
}).strict().superRefine((value, context) => {
  const ids = new Set<string>();
  const classes = new Set<FitnessStorageClass>();
  let total = 0;
  value.measurements.forEach((measurement, index) => {
    if (ids.has(measurement.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['measurements', index, 'id'], message: 'duplicate storage measurement id' });
    }
    ids.add(measurement.id);
    if (classes.has(measurement.storageClass)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['measurements', index, 'storageClass'], message: 'duplicate storage class measurement' });
    }
    classes.add(measurement.storageClass);
    total += measurement.bytes;
  });
  if (total !== value.totalBytes) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['totalBytes'], message: 'storage total must equal the class breakdown' });
  }
});
export type FitnessStorageBreakdown = z.infer<typeof FitnessStorageBreakdown>;

export const FitnessRetentionPolicy = z.object({
  schemaVersion: z.literal(1),
  originalRetentionDays: z.literal(90),
  detailedHistoryRetentionDays: z.literal(365),
  allowOriginalCompaction: z.boolean(),
  allowDetailedHistoryCompaction: z.boolean(),
}).strict();
export type FitnessRetentionPolicy = z.infer<typeof FitnessRetentionPolicy>;

export const FitnessPreservedRecordKind = z.enum(['confirmed_meal', 'correction_lineage', 'inference_provenance']);
export type FitnessPreservedRecordKind = z.infer<typeof FitnessPreservedRecordKind>;

export const FitnessPreservedRecord = z.object({
  id: boundedID,
  kind: FitnessPreservedRecordKind,
  revision,
  updatedAt: observedTimestamp,
  auditRecordID: boundedID,
}).strict();
export type FitnessPreservedRecord = z.infer<typeof FitnessPreservedRecord>;

export const FitnessRetentionAssetKind = z.enum(['original_photo', 'detailed_history']);
export type FitnessRetentionAssetKind = z.infer<typeof FitnessRetentionAssetKind>;

export const FitnessRetentionAsset = z.object({
  id: boundedID,
  kind: FitnessRetentionAssetKind,
  storageClass: FitnessStorageClass,
  bytes: z.number().finite().int().positive().max(maximumStorageBytes),
  observedAt: observedTimestamp,
  revision,
  updatedAt: observedTimestamp,
  pinned: z.boolean(),
  exported: z.boolean(),
  structuredRecordID: boundedID.optional(),
  correctionLineageID: boundedID.optional(),
  provenanceID: boundedID.optional(),
  dailyRollupID: boundedID.optional(),
  weeklyRollupID: boundedID.optional(),
  auditRecordID: boundedID,
}).strict().superRefine((value, context) => {
  if (value.kind === 'original_photo') {
    if (value.storageClass !== 'originals') {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['storageClass'], message: 'original photos must use the originals storage class' });
    }
    for (const field of ['structuredRecordID', 'correctionLineageID', 'provenanceID'] as const) {
      if (value[field] === undefined) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: [field], message: `original photo requires ${field}` });
      }
    }
    if (value.dailyRollupID !== undefined || value.weeklyRollupID !== undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'original photo cannot link sensor rollups' });
    }
  } else {
    if (value.storageClass !== 'detailed_history') {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['storageClass'], message: 'detailed history must use the detailed_history storage class' });
    }
    if (value.dailyRollupID === undefined || value.weeklyRollupID === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'detailed history requires daily and weekly rollup links' });
    }
    if (value.structuredRecordID !== undefined || value.correctionLineageID !== undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'detailed history cannot link meal correction records' });
    }
  }
});
export type FitnessRetentionAsset = z.infer<typeof FitnessRetentionAsset>;

export const FitnessRollupGranularity = z.enum(['daily', 'weekly']);
export type FitnessRollupGranularity = z.infer<typeof FitnessRollupGranularity>;

export const FitnessRollup = z.object({
  id: boundedID,
  granularity: FitnessRollupGranularity,
  periodStart: observedTimestamp,
  periodEnd: observedTimestamp,
  sourceAssetIDs: uniqueIDs(maximumSourceAssetsPerRollup, 1),
  min: metric,
  max: metric,
  mean: metric,
  sampleCount: z.number().finite().int().positive().max(100_000_000),
  sourceCoverage: z.enum(['complete', 'partial']),
  quality: z.enum(['observed', 'estimated', 'partial', 'unavailable']),
  pinnedRawIntervalIDs: uniqueIDs(maximumSourceAssetsPerRollup),
  auditRecordID: boundedID,
  revision,
  updatedAt: observedTimestamp,
}).strict().superRefine((value, context) => {
  if (Date.parse(value.periodEnd) <= Date.parse(value.periodStart)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['periodEnd'], message: 'rollup period must end after it starts' });
  }
  if (value.min > value.max) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['max'], message: 'rollup maximum must be at least its minimum' });
  }
  if (value.mean < value.min || value.mean > value.max) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['mean'], message: 'rollup mean must be within min/max' });
  }
  if (value.sourceCoverage === 'complete' && value.quality === 'unavailable') {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'unavailable rollup cannot claim complete source coverage' });
  }
});
export type FitnessRollup = z.infer<typeof FitnessRollup>;

export const FitnessAuditEntityKind = z.enum(['asset', 'rollup', 'record']);
export type FitnessAuditEntityKind = z.infer<typeof FitnessAuditEntityKind>;
export const FitnessAuditState = z.enum(['active', 'preserved', 'exported', 'compaction_pending', 'compacted', 'restored', 'deleted_tombstone']);
export type FitnessAuditState = z.infer<typeof FitnessAuditState>;

export const FitnessAuditRecord = z.object({
  id: boundedID,
  entityKind: FitnessAuditEntityKind,
  entityID: boundedID,
  state: FitnessAuditState,
  revision,
  recordedAt: observedTimestamp,
}).strict();
export type FitnessAuditRecord = z.infer<typeof FitnessAuditRecord>;

const snapshotShape = {
  schemaVersion: z.literal(1),
  revision,
  observedAt: observedTimestamp,
  storage: FitnessStorageBreakdown,
  retentionPolicy: FitnessRetentionPolicy,
  assets: z.array(FitnessRetentionAsset).max(maximumAssets),
  records: z.array(FitnessPreservedRecord).max(maximumRecords),
  rollups: z.array(FitnessRollup).max(maximumRollups),
  auditRecords: z.array(FitnessAuditRecord).max(maximumAuditRecords),
};

function validateSnapshot(value: SnapshotLike, context: z.RefinementCtx) {
  const snapshotTime = Date.parse(value.observedAt);
  const ensureNotAfterSnapshot = (candidate: string, path: (string | number)[], label: string) => {
    if (Date.parse(candidate) > snapshotTime + maximumClockSkewMs) {
      context.addIssue({ code: z.ZodIssueCode.custom, path, message: `${label} postdates the snapshot` });
    }
  };
  const assetIDs = new Set<string>();
  const recordIDs = new Set<string>();
  const rollupIDs = new Set<string>();
  const auditIDs = new Set<string>();
  const measuredClasses = new Set(value.storage.measurements.map(measurement => measurement.storageClass));

  value.assets.forEach((asset, index) => {
    if (assetIDs.has(asset.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index, 'id'], message: 'duplicate fitness asset id' });
    }
    assetIDs.add(asset.id);
    if (!measuredClasses.has(asset.storageClass)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index, 'storageClass'], message: 'asset storage class is absent from the measurement' });
    }
  });
  value.records.forEach((record, index) => {
    if (recordIDs.has(record.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['records', index, 'id'], message: 'duplicate preserved record id' });
    }
    recordIDs.add(record.id);
  });
  value.rollups.forEach((rollup, index) => {
    if (rollupIDs.has(rollup.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['rollups', index, 'id'], message: 'duplicate rollup id' });
    }
    rollupIDs.add(rollup.id);
  });
  value.auditRecords.forEach((audit, index) => {
    if (auditIDs.has(audit.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['auditRecords', index, 'id'], message: 'duplicate audit record id' });
    }
    auditIDs.add(audit.id);
  });

  const recordsByID = new Map(value.records.map(record => [record.id, record]));
  const assetsByID = new Map(value.assets.map(asset => [asset.id, asset]));
  const rollupsByID = new Map(value.rollups.map(rollup => [rollup.id, rollup]));

  ensureNotAfterSnapshot(value.storage.measuredAt, ['storage', 'measuredAt'], 'storage measurement');
  value.storage.measurements.forEach((measurement, index) => {
    ensureNotAfterSnapshot(measurement.measuredAt, ['storage', 'measurements', index, 'measuredAt'], 'storage class measurement');
  });
  value.assets.forEach((asset, index) => {
    ensureNotAfterSnapshot(asset.observedAt, ['assets', index, 'observedAt'], 'asset observation');
    ensureNotAfterSnapshot(asset.updatedAt, ['assets', index, 'updatedAt'], 'asset update');
  });
  value.records.forEach((record, index) => {
    ensureNotAfterSnapshot(record.updatedAt, ['records', index, 'updatedAt'], 'preserved record update');
  });
  value.rollups.forEach((rollup, index) => {
    ensureNotAfterSnapshot(rollup.periodStart, ['rollups', index, 'periodStart'], 'rollup period');
    ensureNotAfterSnapshot(rollup.periodEnd, ['rollups', index, 'periodEnd'], 'rollup period');
    ensureNotAfterSnapshot(rollup.updatedAt, ['rollups', index, 'updatedAt'], 'rollup update');
  });
  value.auditRecords.forEach((audit, index) => {
    ensureNotAfterSnapshot(audit.recordedAt, ['auditRecords', index, 'recordedAt'], 'audit event');
  });

  const requireRecord = (id: string | undefined, kind: FitnessPreservedRecordKind, path: (string | number)[]) => {
    if (id === undefined) return undefined;
    const record = recordsByID.get(id);
    if (record === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path, message: 'dangling preserved-record link' });
    } else if (record.kind !== kind) {
      context.addIssue({ code: z.ZodIssueCode.custom, path, message: `link must target a ${kind} record` });
    }
    return record;
  };
  const requireAudit = (id: string, entityKind: FitnessAuditEntityKind, entityID: string, path: (string | number)[]) => {
    const audit = value.auditRecords.find(candidate => candidate.id === id);
    if (audit === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path, message: 'dangling audit-record link' });
    } else if (audit.entityKind !== entityKind || audit.entityID !== entityID) {
      context.addIssue({ code: z.ZodIssueCode.custom, path, message: 'audit record points at a different entity' });
    }
    return audit;
  };

  value.records.forEach((record, index) => {
    const audit = requireAudit(record.auditRecordID, 'record', record.id, ['records', index, 'auditRecordID']);
    if (audit?.state === 'deleted_tombstone') {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['records', index], message: 'present preserved record cannot have a deletion tombstone' });
    }
  });

  value.assets.forEach((asset, index) => {
    const audit = requireAudit(asset.auditRecordID, 'asset', asset.id, ['assets', index, 'auditRecordID']);
    if (audit?.state === 'compacted' || audit?.state === 'deleted_tombstone') {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index], message: 'present source asset cannot be compacted or tombstoned' });
    }
    if (audit?.state === 'compaction_pending' && (asset.pinned || asset.exported)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index], message: 'protected asset cannot be compaction-pending' });
    }
    if (audit?.state === 'exported' && !asset.exported) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index], message: 'exported audit state requires exported asset state' });
    }
    if (asset.kind === 'original_photo') {
      requireRecord(asset.structuredRecordID, 'confirmed_meal', ['assets', index, 'structuredRecordID']);
      requireRecord(asset.correctionLineageID, 'correction_lineage', ['assets', index, 'correctionLineageID']);
      requireRecord(asset.provenanceID, 'inference_provenance', ['assets', index, 'provenanceID']);
    } else {
      const daily = asset.dailyRollupID === undefined ? undefined : rollupsByID.get(asset.dailyRollupID);
      const weekly = asset.weeklyRollupID === undefined ? undefined : rollupsByID.get(asset.weeklyRollupID);
      if (daily === undefined) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index, 'dailyRollupID'], message: 'dangling daily rollup link' });
      } else if (daily.granularity !== 'daily' || !daily.sourceAssetIDs.includes(asset.id)) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index, 'dailyRollupID'], message: 'daily rollup link is contradictory' });
      }
      if (weekly === undefined) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index, 'weeklyRollupID'], message: 'dangling weekly rollup link' });
      } else if (weekly.granularity !== 'weekly' || !weekly.sourceAssetIDs.includes(asset.id)) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['assets', index, 'weeklyRollupID'], message: 'weekly rollup link is contradictory' });
      }
    }
  });

  value.rollups.forEach((rollup, index) => {
    const audit = requireAudit(rollup.auditRecordID, 'rollup', rollup.id, ['rollups', index, 'auditRecordID']);
    if (audit?.state === 'deleted_tombstone') {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['rollups', index], message: 'present rollup cannot have a deletion tombstone' });
    }
    for (const [sourceIndex, sourceID] of rollup.sourceAssetIDs.entries()) {
      const source = assetsByID.get(sourceID);
      if (source === undefined) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['rollups', index, 'sourceAssetIDs', sourceIndex], message: 'rollup has a dangling source asset link' });
      } else if (source.kind !== 'detailed_history') {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['rollups', index, 'sourceAssetIDs', sourceIndex], message: 'rollup source must be detailed history' });
      } else {
        const linkedID = rollup.granularity === 'daily' ? source.dailyRollupID : source.weeklyRollupID;
        if (linkedID !== rollup.id) {
          context.addIssue({ code: z.ZodIssueCode.custom, path: ['rollups', index, 'sourceAssetIDs', sourceIndex], message: 'rollup source backlink is contradictory' });
        }
      }
    }
    for (const [pinnedIndex, pinnedID] of rollup.pinnedRawIntervalIDs.entries()) {
      const source = assetsByID.get(pinnedID);
      if (source === undefined || source.kind !== 'detailed_history' || !source.pinned || !rollup.sourceAssetIDs.includes(pinnedID)) {
        context.addIssue({ code: z.ZodIssueCode.custom, path: ['rollups', index, 'pinnedRawIntervalIDs', pinnedIndex], message: 'pinned raw interval link is invalid' });
      }
    }
  });

  value.auditRecords.forEach((audit, index) => {
    const exists = audit.entityKind === 'asset' ? assetsByID.has(audit.entityID)
      : audit.entityKind === 'rollup' ? rollupsByID.has(audit.entityID)
        : recordsByID.has(audit.entityID);
    if (!exists && audit.state !== 'deleted_tombstone') {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['auditRecords', index, 'entityID'], message: 'audit record has a dangling entity link' });
    }
  });
}

type SnapshotLike = {
  observedAt: string;
  storage: FitnessStorageBreakdown;
  assets: FitnessRetentionAsset[];
  records: FitnessPreservedRecord[];
  rollups: FitnessRollup[];
  auditRecords: FitnessAuditRecord[];
};

export const FitnessRetentionSnapshot = z.object(snapshotShape).strict().superRefine(validateSnapshot);
export type FitnessRetentionSnapshot = z.infer<typeof FitnessRetentionSnapshot>;

export const FitnessCompactionRequest = z.object({
  ...snapshotShape,
  planID: boundedID,
  requestedPhotoBytes: bytes.max(maximumPhotoBytesPerRequest).optional(),
}).strict().superRefine(validateSnapshot);
export type FitnessCompactionRequest = z.infer<typeof FitnessCompactionRequest>;

export const FitnessStoragePressure = z.enum(['normal', 'warning', 'aggressive_compaction', 'hard_ingestion_gate']);
export type FitnessStoragePressure = z.infer<typeof FitnessStoragePressure>;
export const FitnessIngestionMode = z.enum(['persistent_photo_allowed', 'structured_only_transient_photo', 'manual_only_no_photo_retention']);
export type FitnessIngestionMode = z.infer<typeof FitnessIngestionMode>;

export const FitnessCompactionEligibility = z.enum(['original_older_than_90_days', 'history_older_than_365_days']);
export type FitnessCompactionEligibility = z.infer<typeof FitnessCompactionEligibility>;
export const FitnessCompactionStep = z.enum(['write_replacement', 'validate_replacement', 'verify_export_and_provenance', 'remove_source_after_commit']);
export type FitnessCompactionStep = z.infer<typeof FitnessCompactionStep>;

const preservationSetShape = {
  structuredRecordIDs: uniqueIDs(maximumRecords),
  correctionLineageIDs: uniqueIDs(maximumRecords),
  provenanceIDs: uniqueIDs(maximumRecords),
  dailyRollupIDs: uniqueIDs(maximumRollups),
  weeklyRollupIDs: uniqueIDs(maximumRollups),
  auditRecordIDs: uniqueIDs(maximumAuditRecords),
};
const preservationSet = z.object(preservationSetShape).strict();
type PreservationSet = z.infer<typeof preservationSet>;

const sourceRemoval = z.object({
  action: z.literal('remove_source_after_validated_commit'),
  requiresExplicitPolicy: z.literal(true),
  auditEventID: boundedID,
}).strict();

const operationBase = {
  operationID: boundedID,
  sourceAssetID: boundedID,
  sourceBytes: bytes,
  reclaimableBytes: bytes,
  eligibility: FitnessCompactionEligibility,
  transactionSteps: z.array(FitnessCompactionStep).length(4),
  sourceDisposition: z.literal('retain_until_commit'),
  sourceRemoval,
};

const originalOperation = z.object({
  ...operationBase,
  kind: z.literal('original_photo'),
  target: z.object({ thumbnailID: boundedID, maximumThumbnailBytes: z.literal(targetDerivativeBytes) }).strict(),
  preserve: preservationSet,
}).strict();
const historyOperation = z.object({
  ...operationBase,
  kind: z.literal('detailed_history'),
  target: z.object({ dailyRollupID: boundedID, weeklyRollupID: boundedID }).strict(),
  preserve: preservationSet,
}).strict();

export const FitnessCompactionOperation = z.discriminatedUnion('kind', [originalOperation, historyOperation]).superRefine((value, context) => {
  const expected: FitnessCompactionStep[] = ['write_replacement', 'validate_replacement', 'verify_export_and_provenance', 'remove_source_after_commit'];
  if (value.transactionSteps.some((step, index) => step !== expected[index])) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['transactionSteps'], message: 'transaction steps must be ordered and complete' });
  }
  const allPreserved = Object.values(value.preserve).flat();
  if (new Set(allPreserved).size !== allPreserved.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['preserve'], message: 'preservation links must be unique across categories' });
  }
  if (value.kind === 'original_photo' && value.eligibility !== 'original_older_than_90_days') {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['eligibility'], message: 'original photo has the wrong eligibility reason' });
  }
  if (value.kind === 'detailed_history' && value.eligibility !== 'history_older_than_365_days') {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['eligibility'], message: 'detailed history has the wrong eligibility reason' });
  }
});
export type FitnessCompactionOperation = z.infer<typeof FitnessCompactionOperation>;

const planShape = {
  schemaVersion: z.literal(1),
  planID: boundedID,
  baseRevision: revision,
  revision,
  createdAt: observedTimestamp,
  updatedAt: observedTimestamp,
  asOf: observedTimestamp,
  storagePressure: FitnessStoragePressure,
  ingestionMode: FitnessIngestionMode,
  requestedPhotoBytes: bytes.max(maximumPhotoBytesPerRequest),
  measuredTotalBytes: z.number().finite().int().nonnegative().max(maximumStorageBytes * maximumMeasurements),
  projectedTotalBytes: z.number().finite().int().nonnegative().max(maximumStorageBytes * maximumMeasurements + maximumPhotoBytesPerRequest),
  operations: z.array(FitnessCompactionOperation).max(maximumAssets),
  estimatedReclaimableBytes: z.number().finite().int().nonnegative().max(maximumStorageBytes * maximumMeasurements),
  protectedBytes: z.number().finite().int().nonnegative().max(maximumStorageBytes * maximumMeasurements),
  preserve: preservationSet,
  execution: z.literal('plan_only_no_deletion'),
  status: z.enum(['planned', 'staging', 'validated', 'committed', 'failed']),
  stagedAt: observedTimestamp.optional(),
  validatedAt: observedTimestamp.optional(),
  validatedOperationIDs: uniqueIDs(maximumAssets).optional(),
  exportVerifiedOperationIDs: uniqueIDs(maximumAssets).optional(),
  committedAt: observedTimestamp.optional(),
  failedAt: observedTimestamp.optional(),
  failureReason: boundedText(500).optional(),
};

export const FitnessCompactionPlan = z.object(planShape).strict().superRefine((value, context) => {
  const operationIDs = new Set<string>();
  const sourceIDs = new Set<string>();
  let reclaimableBytes = 0;
  value.operations.forEach((operation, index) => {
    if (operationIDs.has(operation.operationID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['operations', index, 'operationID'], message: 'duplicate compaction operation id' });
    }
    operationIDs.add(operation.operationID);
    if (sourceIDs.has(operation.sourceAssetID)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['operations', index, 'sourceAssetID'], message: 'duplicate compaction source asset' });
    }
    sourceIDs.add(operation.sourceAssetID);
    if (operation.reclaimableBytes > operation.sourceBytes) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['operations', index, 'reclaimableBytes'], message: 'reclaimable bytes cannot exceed source bytes' });
    }
    reclaimableBytes += operation.reclaimableBytes;
  });
  if (reclaimableBytes !== value.estimatedReclaimableBytes) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['estimatedReclaimableBytes'], message: 'reclaimable bytes must equal planned source bytes' });
  }
  const allPreserved = Object.values(value.preserve).flat();
  if (new Set(allPreserved).size !== allPreserved.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['preserve'], message: 'plan preservation links must be unique across categories' });
  }
  if (value.revision < value.baseRevision) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['revision'], message: 'plan revision cannot precede its base revision' });
  }
  const chronological = (earlier: string, later: string | undefined, path: (string | number)[], label: string) => {
    if (later !== undefined && Date.parse(later) < Date.parse(earlier)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path, message: `${label} precedes the prior plan state` });
    }
  };
  chronological(value.createdAt, value.updatedAt, ['updatedAt'], 'plan update');
  chronological(value.createdAt, value.stagedAt, ['stagedAt'], 'staging');
  chronological(value.stagedAt ?? value.createdAt, value.validatedAt, ['validatedAt'], 'validation');
  chronological(value.validatedAt ?? value.stagedAt ?? value.createdAt, value.committedAt, ['committedAt'], 'commit');
  chronological(value.validatedAt ?? value.stagedAt ?? value.createdAt, value.failedAt, ['failedAt'], 'failure');
  chronological(value.committedAt ?? value.failedAt ?? value.validatedAt ?? value.stagedAt ?? value.createdAt, value.updatedAt, ['updatedAt'], 'plan update');
  if (value.status === 'planned') {
    if (value.stagedAt !== undefined || value.validatedAt !== undefined || value.committedAt !== undefined || value.failedAt !== undefined || value.failureReason !== undefined || value.validatedOperationIDs !== undefined || value.exportVerifiedOperationIDs !== undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'planned compaction cannot carry a later state timestamp or proof' });
    }
  }
  if (value.status === 'staging' && (value.stagedAt === undefined || value.validatedAt !== undefined || value.committedAt !== undefined || value.failedAt !== undefined || value.failureReason !== undefined)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'staging compaction state is contradictory' });
  }
  if (value.status === 'validated' && (value.stagedAt === undefined || value.validatedAt === undefined || value.committedAt !== undefined || value.failedAt !== undefined || value.failureReason !== undefined || value.validatedOperationIDs === undefined || value.exportVerifiedOperationIDs === undefined)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'validated compaction state is incomplete or contradictory' });
  }
  if (value.status === 'committed' && (value.stagedAt === undefined || value.validatedAt === undefined || value.committedAt === undefined || value.failedAt !== undefined || value.failureReason !== undefined || value.validatedOperationIDs === undefined || value.exportVerifiedOperationIDs === undefined)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'committed compaction state is incomplete or contradictory' });
  }
  if (value.status === 'failed' && (value.failedAt === undefined || value.failureReason === undefined || value.committedAt !== undefined)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'failed compaction state requires a reason and cannot be committed' });
  }
});
export type FitnessCompactionPlan = z.infer<typeof FitnessCompactionPlan>;

export const FitnessCompactionTransition = z.object({
  transitionID: boundedID,
  planID: boundedID,
  expectedRevision: revision,
  event: z.enum(['begin', 'validate', 'commit', 'fail', 'retry']),
  occurredAt: observedTimestamp,
  validatedOperationIDs: uniqueIDs(maximumAssets).optional(),
  exportVerifiedOperationIDs: uniqueIDs(maximumAssets).optional(),
  failureReason: boundedText(500).optional(),
}).strict().superRefine((value, context) => {
  if (value.event === 'validate') {
    if (value.validatedOperationIDs === undefined || value.exportVerifiedOperationIDs === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'validate requires replacement and export/provenance proofs' });
    }
    if (value.failureReason !== undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['failureReason'], message: 'validate cannot carry a failure reason' });
    }
  } else if (value.event === 'fail') {
    if (value.failureReason === undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['failureReason'], message: 'fail requires a bounded reason' });
    }
    if (value.validatedOperationIDs !== undefined || value.exportVerifiedOperationIDs !== undefined) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: 'fail cannot carry successful validation proofs' });
    }
  } else if (value.validatedOperationIDs !== undefined || value.exportVerifiedOperationIDs !== undefined || value.failureReason !== undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: `${value.event} cannot carry validation or failure fields` });
  }
});
export type FitnessCompactionTransition = z.infer<typeof FitnessCompactionTransition>;

function stableTag(value: string): string {
  let hash = 2_166_136_261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

function derivedID(prefix: string, ...parts: string[]) {
  return `${prefix}-${stableTag(parts.join('|'))}`;
}

function pressureFor(totalBytes: number): FitnessStoragePressure {
  if (totalBytes >= FITNESS_STORAGE_LIMITS.hardCapBytes) return 'hard_ingestion_gate';
  if (totalBytes >= FITNESS_STORAGE_LIMITS.aggressiveCompactionBytes) return 'aggressive_compaction';
  if (totalBytes >= FITNESS_STORAGE_LIMITS.warningBytes) return 'warning';
  return 'normal';
}

function ingestionModeFor(totalBytes: number): FitnessIngestionMode {
  if (totalBytes >= FITNESS_STORAGE_LIMITS.hardCapBytes) return 'manual_only_no_photo_retention';
  if (totalBytes >= FITNESS_STORAGE_LIMITS.aggressiveCompactionBytes) return 'structured_only_transient_photo';
  return 'persistent_photo_allowed';
}

function makePreservationSet(): PreservationSet {
  return {
    structuredRecordIDs: [],
    correctionLineageIDs: [],
    provenanceIDs: [],
    dailyRollupIDs: [],
    weeklyRollupIDs: [],
    auditRecordIDs: [],
  };
}

function addUnique(values: string[], value: string) {
  if (!values.includes(value)) values.push(value);
}

/**
 * Purely plans due work against a validated snapshot.  It does not write
 * thumbnails/rollups, export anything, or delete the source assets.
 */
export function planFitnessCompaction(input: FitnessCompactionRequest): FitnessCompactionPlan {
  const request = FitnessCompactionRequest.parse(input);
  const requestedPhotoBytes = request.requestedPhotoBytes ?? 0;
  const projectedTotalBytes = request.storage.totalBytes + requestedPhotoBytes;
  const storagePressure = pressureFor(projectedTotalBytes);
  const ingestionMode = ingestionModeFor(projectedTotalBytes);
  const preserve = makePreservationSet();
  const operations: FitnessCompactionOperation[] = [];
  const asOfMilliseconds = Date.parse(request.observedAt);

  for (const asset of request.assets) {
    const ageMilliseconds = asOfMilliseconds - Date.parse(asset.observedAt);
    const originalDue = asset.kind === 'original_photo'
      && request.retentionPolicy.allowOriginalCompaction
      && ageMilliseconds >= request.retentionPolicy.originalRetentionDays * dayMilliseconds;
    const historyDue = asset.kind === 'detailed_history'
      && request.retentionPolicy.allowDetailedHistoryCompaction
      && ageMilliseconds >= request.retentionPolicy.detailedHistoryRetentionDays * dayMilliseconds;
    if ((!originalDue && !historyDue) || asset.pinned || asset.exported) continue;

    const operationID = derivedID('fitness-op', request.planID, asset.id);
    const auditEventID = derivedID('fitness-audit', request.planID, asset.id);
    const common = {
      operationID,
      sourceAssetID: asset.id,
      sourceBytes: asset.bytes,
      reclaimableBytes: originalDue ? Math.max(0, asset.bytes - targetDerivativeBytes) : asset.bytes,
      eligibility: originalDue ? 'original_older_than_90_days' as const : 'history_older_than_365_days' as const,
      transactionSteps: ['write_replacement', 'validate_replacement', 'verify_export_and_provenance', 'remove_source_after_commit'] as FitnessCompactionStep[],
      sourceDisposition: 'retain_until_commit' as const,
      sourceRemoval: { action: 'remove_source_after_validated_commit' as const, requiresExplicitPolicy: true as const, auditEventID },
    };
    if (asset.kind === 'original_photo') {
      const operation: FitnessCompactionOperation = {
        ...common,
        kind: 'original_photo',
        target: { thumbnailID: derivedID('fitness-thumb', asset.id), maximumThumbnailBytes: targetDerivativeBytes },
        preserve: {
          structuredRecordIDs: [asset.structuredRecordID!],
          correctionLineageIDs: [asset.correctionLineageID!],
          provenanceIDs: [asset.provenanceID!],
          dailyRollupIDs: [], weeklyRollupIDs: [], auditRecordIDs: [asset.auditRecordID],
        },
      };
      operations.push(operation);
      addUnique(preserve.structuredRecordIDs, asset.structuredRecordID!);
      addUnique(preserve.correctionLineageIDs, asset.correctionLineageID!);
      addUnique(preserve.provenanceIDs, asset.provenanceID!);
      addUnique(preserve.auditRecordIDs, asset.auditRecordID);
    } else {
      const operation: FitnessCompactionOperation = {
        ...common,
        kind: 'detailed_history',
        target: { dailyRollupID: asset.dailyRollupID!, weeklyRollupID: asset.weeklyRollupID! },
        preserve: {
          structuredRecordIDs: [], correctionLineageIDs: [], provenanceIDs: [],
          dailyRollupIDs: [asset.dailyRollupID!], weeklyRollupIDs: [asset.weeklyRollupID!], auditRecordIDs: [asset.auditRecordID],
        },
      };
      operations.push(operation);
      addUnique(preserve.dailyRollupIDs, asset.dailyRollupID!);
      addUnique(preserve.weeklyRollupIDs, asset.weeklyRollupID!);
      addUnique(preserve.auditRecordIDs, asset.auditRecordID);
    }
  }

  const estimatedReclaimableBytes = operations.reduce((total, operation) => total + operation.reclaimableBytes, 0);
  const protectedBytes = request.assets.filter(asset => asset.pinned || asset.exported).reduce((total, asset) => total + asset.bytes, 0);
  const plan = {
    schemaVersion: 1 as const,
    planID: request.planID,
    baseRevision: request.revision,
    revision: request.revision,
    createdAt: request.observedAt,
    updatedAt: request.observedAt,
    asOf: request.observedAt,
    storagePressure,
    ingestionMode,
    requestedPhotoBytes,
    measuredTotalBytes: request.storage.totalBytes,
    projectedTotalBytes,
    operations,
    estimatedReclaimableBytes,
    protectedBytes,
    preserve,
    execution: 'plan_only_no_deletion' as const,
    status: 'planned' as const,
  };
  return FitnessCompactionPlan.parse(plan);
}

function sameIDs(left: string[] | undefined, right: string[]) {
  return left !== undefined && left.length === right.length && right.every(id => left.includes(id));
}

function nextRevision(current: number) {
  if (current >= maximumRevision) throw new Error('compaction plan revision exhausted');
  return current + 1;
}

/** Pure, optimistic-concurrency-safe transaction state transition. */
export function advanceFitnessCompactionPlan(planInput: FitnessCompactionPlan, transitionInput: FitnessCompactionTransition): FitnessCompactionPlan {
  const plan = FitnessCompactionPlan.parse(planInput);
  const transition = FitnessCompactionTransition.parse(transitionInput);
  if (transition.planID !== plan.planID) throw new Error('compaction transition targets a different plan');
  if (transition.expectedRevision !== plan.revision) throw new Error('stale compaction plan revision');
  if (Date.parse(transition.occurredAt) < Date.parse(plan.updatedAt)) throw new Error('compaction transition predates the current plan state');

  const operationIDs = plan.operations.map(operation => operation.operationID);
  let next: Record<string, unknown> = {
    ...plan,
    revision: nextRevision(plan.revision),
    updatedAt: transition.occurredAt,
  };

  switch (transition.event) {
    case 'begin':
      if (plan.status !== 'planned') throw new Error('begin is only valid for a planned compaction');
      next = { ...next, status: 'staging', stagedAt: transition.occurredAt };
      break;
    case 'validate':
      if (plan.status !== 'staging') throw new Error('validate is only valid while staging');
      if (!sameIDs(transition.validatedOperationIDs, operationIDs) || !sameIDs(transition.exportVerifiedOperationIDs, operationIDs)) {
        throw new Error('validation must cover every compaction operation');
      }
      next = {
        ...next,
        status: 'validated',
        validatedAt: transition.occurredAt,
        validatedOperationIDs: [...operationIDs],
        exportVerifiedOperationIDs: [...operationIDs],
      };
      break;
    case 'commit':
      if (plan.status !== 'validated' || !sameIDs(plan.validatedOperationIDs, operationIDs) || !sameIDs(plan.exportVerifiedOperationIDs, operationIDs)) {
        throw new Error('commit requires complete validated and export/provenance proofs');
      }
      next = { ...next, status: 'committed', committedAt: transition.occurredAt };
      break;
    case 'fail':
      if (plan.status === 'committed' || plan.status === 'failed') throw new Error('committed or failed compaction cannot fail again');
      next = { ...next, status: 'failed', failedAt: transition.occurredAt, failureReason: transition.failureReason };
      break;
    case 'retry':
      if (plan.status !== 'failed') throw new Error('retry is only valid after a failed compaction');
      next = {
        ...next,
        status: 'staging',
        stagedAt: transition.occurredAt,
        validatedAt: undefined,
        validatedOperationIDs: undefined,
        exportVerifiedOperationIDs: undefined,
        committedAt: undefined,
        failedAt: undefined,
        failureReason: undefined,
      };
      break;
  }
  return FitnessCompactionPlan.parse(next);
}

export const FitnessRetentionConstants = {
  maximumClockSkewMs,
  maximumStorageBytes,
  maximumPhotoBytesPerRequest,
  targetDerivativeBytes,
} as const;
