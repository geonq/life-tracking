import { describe, expect, it } from 'vitest';
import {
  assertOpenedDirectoryIdentity,
  validateWindowsAclSddl,
} from './atomic-file.js';

const operatorSid = 'S-1-5-21-100-200-300-400';
const serviceSid = 'S-1-5-80-111-222-333-444-555';
const foreignSid = 'S-1-5-21-400-500-600-700';

describe('atomic storage security boundaries', () => {
  it('rejects a foreign full-control owner even when the current service is trusted', () => {
    expect(() => validateWindowsAclSddl(
      `O:${foreignSid}G:SYD:(A;;FA;;;${foreignSid})`,
      serviceSid,
      operatorSid,
    )).toThrow('unsafe_storage_contract');
  });

  it('rejects unsupported ACE types instead of ignoring conditional grants', () => {
    expect(() => validateWindowsAclSddl(
      `O:${serviceSid}G:SYD:(XA;;FA;;;${foreignSid})`,
      serviceSid,
      operatorSid,
    )).toThrow('unsafe_storage_contract');
  });

  it('accepts deployment management principals and read-only broad inheritance', () => {
    expect(() => validateWindowsAclSddl(
      `O:${operatorSid}G:SYD:(A;;FA;;;${operatorSid})(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;WD)`,
      serviceSid,
      operatorSid,
    )).not.toThrow();
  });

  it('rejects a descriptor whose opened parent differs from the pre-open identity', () => {
    const expected = [2, 10, 0o40700] as const;
    expect(() => assertOpenedDirectoryIdentity(
      { dev: 2, ino: 11, mode: 0o40700, isDirectory: () => true },
      expected,
    )).toThrow('unsafe_write_directory');
    expect(() => assertOpenedDirectoryIdentity(
      { dev: 2, ino: 10, mode: 0o40700, isDirectory: () => true },
      expected,
    )).not.toThrow();
  });
});
