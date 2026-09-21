import { describe, expect, it } from 'vitest';
import {
  AdminBlobRead20,
  AdminBlobPut20,
  ObservationAccess20,
  RemotePackSource20,
  MAX_INLINE_PAYLOAD_BYTES,
  SyncOperation,
  canonicalJSON,
  encodeSyncOperation,
  operationHash,
  operationSigningBytes,
  parseStrictJSON,
  parseSyncOperation,
  sha256Hex,
} from './replication.js';

const emptyHash = sha256Hex(new Uint8Array());
const operation = SyncOperation.parse({
  schemaVersion: 1,
  datasetID: '11111111-1111-4111-8111-111111111111',
  epoch: '1',
  storeID: '22222222-2222-4222-8222-222222222222',
  domain: 'calendar' as const,
  originID: '33333333-3333-4333-8333-333333333333',
  keyID: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sequence: '9007199254740993',
  mutationID: '44444444-4444-4444-8444-444444444444',
  entityID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  parents: [],
  baseHash: null,
  kind: 'bootstrap' as const,
  payload: {
    schemaVersion: 1,
    hash: emptyHash,
    byteCount: 0,
    inline: '',
    blobHash: null,
  },
  signature: 'A'.repeat(86),
});

describe('replication contract', () => {
  it('sorts canonical object keys and preserves decimal sequence strings', () => {
    const encoded = encodeSyncOperation(operation);
    expect(new TextDecoder().decode(encoded).startsWith('{"baseHash"')).toBe(true);
    expect(parseSyncOperation(JSON.parse(new TextDecoder().decode(encoded))).sequence).toBe('9007199254740993');
    expect(operationSigningBytes(operation).byteLength).toBeGreaterThan(32);
    expect(operationHash(operation)).toMatch(/^[0-9a-f]{64}$/);
    expect(canonicalJSON({ z: 1, a: 2 })).toBe('{"a":2,"z":1}');
  });

  it('rejects unknown fields, leading-zero counters, and invalid inline bytes', () => {
    expect(() => parseSyncOperation({ ...operation, unexpected: true })).toThrow();
    expect(() => parseSyncOperation({ ...operation, sequence: '01' })).toThrow();
    expect(() => parseSyncOperation({
      ...operation,
      payload: { ...operation.payload, inline: 'YQ', byteCount: 0 },
    })).toThrow();
  });

  it('rejects duplicate keys before JSON.parse loses them', () => {
    expect(() => parseStrictJSON('{"schemaVersion":1,"schemaVersion":1}')).toThrow(/duplicate/);
    expect(parseStrictJSON('{"schemaVersion":1,"nested":{"ok":true}}')).toEqual({
      schemaVersion: 1,
      nested: { ok: true },
    });
  });

  it('keeps administrative blobs in the closed restore namespace', () => {
    const value = {
      schemaVersion: 20,
      scope: {
        namespace: 'data.restore.v20',
        datasetID: '11111111-1111-4111-8111-111111111111',
        operationID: '22222222-2222-4222-8222-222222222222',
        fenceID: '33333333-3333-4333-8333-333333333333',
        targetHostID: '44444444-4444-4444-8444-444444444444',
        storeID: 'usageLocal',
      },
      blobHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      totalBytes: '0',
      offset: '0',
      chunkHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      bytesBase64URL: '',
      isFinal: true,
    };
    expect(AdminBlobPut20.parse(value).scope.storeID).toBe('usageLocal');
    expect(canonicalJSON(AdminBlobPut20.parse(value))).toContain('"totalBytes":"0"');
    expect(() => AdminBlobPut20.parse({ ...value, totalBytes: 0 })).toThrow();
    expect(() => AdminBlobPut20.parse({
      ...value,
      scope: { ...value.scope, storeID: 'calendar' },
    })).toThrow();
  });

  it('keeps administrative and observation counters as bounded decimal strings', () => {
    const scope = {
      namespace: 'data.restore.v20' as const,
      datasetID: '11111111-1111-4111-8111-111111111111',
      operationID: '22222222-2222-4222-8222-222222222222',
      fenceID: '33333333-3333-4333-8333-333333333333',
      targetHostID: '44444444-4444-4444-8444-444444444444',
      storeID: 'usageLocal' as const,
    };
    const read = {
      schemaVersion: 20 as const,
      scope,
      blobHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      offset: '33554432',
      limit: '262144',
    };
    expect(AdminBlobRead20.parse(read).limit).toBe('262144');
    expect(canonicalJSON(AdminBlobRead20.parse(read))).toContain('"limit":"262144"');
    expect(() => AdminBlobRead20.parse({ ...read, limit: 262144 })).toThrow();
    expect(() => AdminBlobRead20.parse({ ...read, limit: '262145' })).toThrow();

    const observation = {
      schemaVersion: 20 as const,
      datasetID: scope.datasetID,
      epoch: '1',
      originID: scope.operationID,
      originKeyID: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      readerKeyIDs: [],
      ownerKeyID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      signature: 'A'.repeat(86),
    };
    expect(ObservationAccess20.parse(observation).epoch).toBe('1');
    expect(() => ObservationAccess20.parse({ ...observation, epoch: 1 })).toThrow();
    expect(() => ObservationAccess20.parse({ ...observation, epoch: '0' })).toThrow();
    expect(() => ObservationAccess20.parse({ ...observation, epoch: '01' })).toThrow();
  });

  it('enforces administrative bundle and segment ceilings', () => {
    const source = {
      schemaVersion: 20 as const,
      namespace: 'data.restore.v20' as const,
      datasetID: '11111111-1111-4111-8111-111111111111',
      operationID: '22222222-2222-4222-8222-222222222222',
      fenceID: '33333333-3333-4333-8333-333333333333',
      targetHostID: '44444444-4444-4444-8444-444444444444',
      storeID: 'clipperLocal' as const,
      packHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sourceHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      manifestFormat: 'packObjectV7' as const,
      manifestHash: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      manifestByteCount: '268435456',
      bundleHash: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
      byteCount: '536870929',
      segments: [{
        index: 0,
        blobHash: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        byteCount: '33554432',
      }],
    };
    expect(RemotePackSource20.parse(source).byteCount).toBe('536870929');
    expect(() => RemotePackSource20.parse({ ...source, byteCount: '536870930' })).toThrow();
    expect(() => RemotePackSource20.parse({ ...source, manifestByteCount: '268435457' })).toThrow();
    expect(() => RemotePackSource20.parse({
      ...source,
      segments: [{ ...source.segments[0], byteCount: '33554433' }],
    })).toThrow();
  });

  it('rejects payloads above the inline cap before accepting them', () => {
    const bytes = new Uint8Array(MAX_INLINE_PAYLOAD_BYTES + 1);
    const inline = Buffer.from(bytes).toString('base64url');
    expect(() => SyncOperation.parse({
      ...operation,
      payload: {
        ...operation.payload,
        inline,
        byteCount: bytes.byteLength,
        hash: sha256Hex(bytes),
      },
    })).toThrow();
  });
});
