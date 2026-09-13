import { describe, expect, it } from 'vitest';
import {
  encodeFinanceImportedSyncRequest,
  FinanceImportedSyncRequest,
  FinanceImportedSyncSnapshot,
} from './sync.js';

const observedAt = new Date(Date.now() - 1_000).toISOString();
const recordID = '00000000-0000-4000-8000-000000000001';

const newRecord = {
  recordID,
  sourceRevision: 0,
  bookedAt: observedAt,
  amountCents: -1890,
  description: 'Restaurant',
  categoryOverride: null,
  sourceCategory: 'Food',
  providerCode: null,
  source: 'tradeRepublicCSV' as const,
  importedAt: observedAt,
  kind: 'cash' as const,
  investment: null,
};

const observedRecord = { ...newRecord, sourceRevision: 1 };

const request = (operations: unknown[], baseRevision = 0) => ({
  schemaVersion: 2,
  baseRevision,
  operations,
});

describe('manual imported-finance synchronization contract v2', () => {
  it('accepts source, category-only, delete, and explicit restore operations', () => {
    const parsed = FinanceImportedSyncRequest.parse(request([
      { operation: 'upsert', record: newRecord, expectedSourceRevision: 0 },
    ]));
    expect(parsed.operations[0]).toMatchObject({ operation: 'upsert', expectedSourceRevision: 0 });

    expect(FinanceImportedSyncRequest.parse(request([
      { operation: 'categorySet', recordID, expectedSourceRevision: 1, categoryOverride: 'groceries' },
    ], 1)).operations[0]).toMatchObject({ operation: 'categorySet' });
    expect(FinanceImportedSyncRequest.parse(request([
      { operation: 'categoryClear', recordID, expectedSourceRevision: 1 },
    ], 1)).operations[0]).toMatchObject({ operation: 'categoryClear' });
    expect(FinanceImportedSyncRequest.parse(request([
      { operation: 'delete', recordID, expectedSourceRevision: 1, deletedAt: observedAt },
    ], 1)).operations[0]).toMatchObject({ operation: 'delete' });
    expect(FinanceImportedSyncRequest.parse(request([
      { operation: 'restore', record: newRecord, expectedTombstoneRevision: 4 },
    ], 4)).operations[0]).toMatchObject({ operation: 'restore' });
  });

  it('normalizes case-equivalent UUID text and preserves explicit nulls', () => {
    const upper = recordID.toUpperCase();
    const parsed = FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert',
      record: { ...newRecord, recordID: upper },
      expectedSourceRevision: 0,
    }]));
    const operation = parsed.operations[0];
    expect(operation.operation).toBe('upsert');
    if (operation.operation === 'upsert') {
      expect(operation.record.recordID).toBe(recordID);
      expect(operation.record.categoryOverride).toBeNull();
      expect(operation.record.providerCode).toBeNull();
      expect(operation.record.investment).toBeNull();
    }
  });

  it('uses UTF-8 byte limits and rejects surrounding whitespace consistently', () => {
    expect(FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert',
      record: { ...newRecord, description: 'é'.repeat(256) },
      expectedSourceRevision: 0,
    }]))).toBeTruthy();

    for (const description of [' Restaurant', 'Restaurant ', 'é'.repeat(257)]) {
      expect(() => FinanceImportedSyncRequest.parse(request([{
        operation: 'upsert',
        record: { ...newRecord, description },
        expectedSourceRevision: 0,
      }]))).toThrow();
    }
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert',
      record: { ...newRecord, sourceCategory: ' Food ' },
      expectedSourceRevision: 0,
    }]))).toThrow();
  });

  it('requires immutable source preconditions and rejects invalid numeric values', () => {
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert', record: newRecord, expectedSourceRevision: 1,
    }]))).toThrow();
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert', record: { ...newRecord, amountCents: 1.5 }, expectedSourceRevision: 0,
    }]))).toThrow();
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert', record: { ...newRecord, amountCents: true }, expectedSourceRevision: 0,
    }]))).toThrow();
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'restore', record: observedRecord, expectedTombstoneRevision: 4,
    }], 4))).toThrow();
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert', record: {
        ...newRecord,
        investment: {
          symbol: null, assetClass: null, quantity: null, unitPriceCents: null,
          tradeType: null, currency: 'eur',
        },
        kind: 'investmentOrder',
      }, expectedSourceRevision: 0,
    }]))).toThrow();
  });

  it('rejects duplicate IDs and every unknown key, including the old v1 operation shape', () => {
    expect(() => FinanceImportedSyncRequest.parse(request([
      { operation: 'delete', recordID, expectedSourceRevision: 1, deletedAt: observedAt },
      { operation: 'categoryClear', recordID, expectedSourceRevision: 1 },
    ], 1))).toThrow();
    expect(() => FinanceImportedSyncRequest.parse({
      ...request([{ operation: 'categoryClear', recordID, expectedSourceRevision: 1 }], 1),
      unknown: true,
    })).toThrow();
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert', record: newRecord, expectedSourceRevision: 0, unknown: true,
    }]))).toThrow();
    expect(() => FinanceImportedSyncRequest.parse(request([{
      operation: 'upsert', record: newRecord, categoryOverrideAction: 'preserve', expectedSourceRevision: 0,
    }]))).toThrow();
  });

  it('enforces snapshot source revisions, tombstone rules, and strict envelope keys', () => {
    const valid = FinanceImportedSyncSnapshot.parse({
      schemaVersion: 2,
      domain: 'finance',
      ledger: 'manual_import',
      authority: 'gateway',
      revision: 2,
      records: [{ ...observedRecord, recordID }],
      tombstones: [],
    });
    expect(valid.records[0].sourceRevision).toBe(1);

    expect(() => FinanceImportedSyncSnapshot.parse({
      ...valid,
      records: [{ ...observedRecord, sourceRevision: 0 }],
    })).toThrow();
    expect(() => FinanceImportedSyncSnapshot.parse({
      ...valid,
      records: [{ ...observedRecord, sourceRevision: 3 }],
    })).toThrow();
    expect(() => FinanceImportedSyncSnapshot.parse({
      ...valid,
      records: [{ ...observedRecord, recordID }],
      tombstones: [{ recordID, revision: 2, deletedAt: observedAt }],
    })).toThrow();
    expect(() => FinanceImportedSyncSnapshot.parse({
      ...valid,
      tombstones: [{ recordID: '00000000-0000-4000-8000-000000000002', revision: 3, deletedAt: observedAt }],
    })).toThrow();
    expect(() => FinanceImportedSyncSnapshot.parse({ ...valid, unknown: true })).toThrow();
  });

  it('caps canonical request bytes after parsing and sorting keys', () => {
    const operations = Array.from({ length: 384 }, (_, index) => ({
      operation: 'upsert' as const,
      record: {
        ...newRecord,
        recordID: `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
        description: 'x'.repeat(512),
        sourceCategory: 'y'.repeat(128),
        providerCode: 'z'.repeat(64),
      },
      expectedSourceRevision: 0,
    }));
    const encoded = encodeFinanceImportedSyncRequest(request(operations));
    expect(encoded.byteLength).toBeLessThanOrEqual(512 * 1024);

    const oversized = operations.map(operation => ({
      ...operation,
      record: { ...operation.record, kind: 'investmentOrder' as const, investment: {
        symbol: 's'.repeat(64), assetClass: 'a'.repeat(64), quantity: 'q'.repeat(128),
        unitPriceCents: 1, tradeType: 't'.repeat(64), currency: 'EUR' as const,
      } },
    }));
    expect(() => encodeFinanceImportedSyncRequest(request(oversized))).toThrow(/byte cap/);
  });
});
