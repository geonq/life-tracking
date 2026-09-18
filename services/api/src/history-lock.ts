import { randomUUID } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { lstat, mkdir, open, stat, unlink } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import {
  assertFilePathIdentityChain,
  assertOpenedDirectoryIdentity,
  assertStoragePathContract,
  captureFilePathIdentityChain,
  type FilePathIdentityChain,
} from './atomic-file.js';

/** A lock payload is metadata only; the lock file itself is the ownership primitive. */
export const MAX_HISTORY_LOCK_BYTES = 1024;
export const HISTORY_LOCK_DEFAULT_DEADLINE_MS = 5_000;
export const HISTORY_LOCK_DEFAULT_POLL_INTERVAL_MS = 25;
const HISTORY_LOCK_SCHEMA_VERSION = 1;
const HISTORY_LOCK_FILE_SUFFIX = '.lock';
const optionalOpenFlag = (name: 'O_CLOEXEC' | 'O_NOFOLLOW'): number =>
  (fsConstants as unknown as Record<string, number | undefined>)[name] ?? 0;
const directoryOpenFlags = fsConstants.O_RDONLY
  | (fsConstants.O_DIRECTORY ?? 0)
  | optionalOpenFlag('O_NOFOLLOW')
  | optionalOpenFlag('O_CLOEXEC');
const lockCreateFlags = fsConstants.O_WRONLY
  | fsConstants.O_CREAT
  | fsConstants.O_EXCL
  | optionalOpenFlag('O_NOFOLLOW')
  | optionalOpenFlag('O_CLOEXEC');
const lockReadFlags = fsConstants.O_RDONLY
  | optionalOpenFlag('O_NOFOLLOW')
  | optionalOpenFlag('O_CLOEXEC');

export type HistoryWriteLockReason =
  | 'history_lock_timeout'
  | 'history_lock_not_owned'
  | 'history_lock_unavailable';

/**
 * A lock failure is intentionally separate from UsageHistoryError to avoid a
 * module cycle. UsageHistory maps it to its existing storage_unavailable
 * taxonomy before the error reaches an API caller.
 */
export class HistoryWriteLockError extends Error {
  readonly code = 'storage_unavailable' as const;
  readonly reason: HistoryWriteLockReason;

  constructor(reason: HistoryWriteLockReason, cause?: unknown) {
    super(reason, cause === undefined ? undefined : { cause });
    this.name = 'HistoryWriteLockError';
    this.reason = reason;
  }
}

export type HistoryWriteLockOptions = {
  /** Total time spent waiting for another writer, including polling sleeps. */
  deadlineMs?: number;
  /** Delay between exclusive-create attempts. The production default is bounded and non-zero. */
  pollIntervalMs?: number;
  /** Injectable monotonic clock for deterministic contention tests. */
  monotonicNow?: () => number;
  /** Backward-compatible test seam; supplied clocks are treated as monotonic. */
  now?: () => number;
  /** Injectable non-busy wait for deterministic contention tests. */
  sleep?: (milliseconds: number) => Promise<void>;
  /** Test-only seam; production always uses a cryptographically random UUID. */
  ownerToken?: string;
  /** Test-only hook invoked after an exclusive-create contention. */
  onContention?: (attempt: number) => void | Promise<void>;
  /** Test-only hook used to hold the release promise after unlinking. */
  afterUnlink?: () => void | Promise<void>;
};

type DirectoryHandle = Awaited<ReturnType<typeof open>>;

type LockContext = {
  parent: string;
  parentChain: FilePathIdentityChain;
  lockPath: string;
  createPath: string;
  releasePath: string;
  directory?: DirectoryHandle;
  afterUnlink?: () => void | Promise<void>;
};

type LockPayload = {
  schemaVersion: typeof HISTORY_LOCK_SCHEMA_VERSION;
  owner: string;
  pid: number;
  acquiredAt: number;
};

function isOwnerToken(value: unknown): value is string {
  return typeof value === 'string' && /^[\x21-\x7e]{8,128}$/.test(value);
}

function isFiniteSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && Number.isFinite(value);
}

function sameFileIdentity(
  left: { dev: number; ino: number; mode: number },
  right: { dev: number; ino: number; mode: number },
): boolean {
  return left.dev === right.dev && left.ino === right.ino && left.mode === right.mode;
}

function validateDuration(value: number | undefined, fallback: number, maximum: number): number {
  const resolved = value ?? fallback;
  if (!Number.isSafeInteger(resolved) || resolved < 0 || resolved > maximum) {
    throw new RangeError('invalid_history_lock_timing');
  }
  return resolved;
}

function validatePollInterval(value: number | undefined): number {
  const resolved = value ?? HISTORY_LOCK_DEFAULT_POLL_INTERVAL_MS;
  if (!Number.isSafeInteger(resolved) || resolved < 1 || resolved > 1_000) {
    throw new RangeError('invalid_history_lock_timing');
  }
  return resolved;
}

async function descriptorRelativePath(directory: DirectoryHandle, name: string): Promise<string | undefined> {
  if (process.platform === 'win32') return undefined;
  for (const root of ['/proc/self/fd', '/dev/fd']) {
    try {
      const observed = await stat(`${root}/${directory.fd}/.`);
      if (observed.isDirectory()) return join(root, String(directory.fd), name);
    } catch {
      // Try the next platform-provided descriptor namespace.
    }
  }
  return undefined;
}

async function prepareLockContext(
  historyFile: string,
  afterUnlink?: () => void | Promise<void>,
): Promise<LockContext> {
  const target = resolve(historyFile);
  const parent = dirname(target);
  const lockPath = `${target}${HISTORY_LOCK_FILE_SUFFIX}`;

  // The existing writer creates missing storage directories with this same
  // private mode. Capture the identity after creation, then authenticate it
  // before any lock child is created.
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const parentChain = await captureFilePathIdentityChain(parent);
  if (parentChain[parentChain.length - 1]?.[0] !== parent) {
    throw new HistoryWriteLockError('history_lock_unavailable');
  }
  await assertStoragePathContract(parent, parentChain);

  let directory: DirectoryHandle | undefined;
  let createPath = lockPath;
  let releasePath = lockPath;
  if (process.platform !== 'win32') {
    if (fsConstants.O_DIRECTORY === undefined) {
      throw new HistoryWriteLockError('history_lock_unavailable');
    }
    const expected = parentChain[parentChain.length - 1]?.[1];
    if (expected === undefined) throw new HistoryWriteLockError('history_lock_unavailable');
    try {
      directory = await open(parent, directoryOpenFlags);
      assertOpenedDirectoryIdentity(await directory.stat(), expected);
      const relative = await descriptorRelativePath(directory, basename(lockPath));
      if (relative !== undefined) {
        createPath = relative;
        releasePath = relative;
      } else {
        await directory.close();
        directory = undefined;
      }
    } catch (error) {
      await directory?.close().catch(() => undefined);
      throw new HistoryWriteLockError('history_lock_unavailable', error);
    }
  }

  return { parent, parentChain, lockPath, createPath, releasePath, directory, afterUnlink };
}

function encodePayload(payload: LockPayload): Buffer {
  const encoded = Buffer.from(JSON.stringify(payload), 'utf8');
  if (encoded.byteLength > MAX_HISTORY_LOCK_BYTES) {
    throw new HistoryWriteLockError('history_lock_unavailable');
  }
  return encoded;
}

function decodeOwner(body: Buffer): string | undefined {
  try {
    const decoded = JSON.parse(body.toString('utf8')) as Partial<LockPayload> & Record<string, unknown>;
    if (
      Object.keys(decoded).length !== 4
      || decoded.schemaVersion !== HISTORY_LOCK_SCHEMA_VERSION
      || !isOwnerToken(decoded.owner)
      || !isFiniteSafeInteger(decoded.pid)
      || decoded.pid < 0
      || typeof decoded.acquiredAt !== 'number'
      || !Number.isFinite(decoded.acquiredAt)
    ) return undefined;
    return decoded.owner;
  } catch {
    return undefined;
  }
}

async function readOwner(context: LockContext, lockChain: FilePathIdentityChain): Promise<string | undefined> {
  let descriptor: DirectoryHandle | undefined;
  try {
    const before = await lstat(context.lockPath);
    if (!before.isFile() || before.isSymbolicLink() || before.size > MAX_HISTORY_LOCK_BYTES) return undefined;
    descriptor = await open(context.releasePath, lockReadFlags);
    const opened = await descriptor.stat();
    if (!opened.isFile() || opened.isSymbolicLink() || !sameFileIdentity(opened, before)) return undefined;

    const buffer = Buffer.alloc(MAX_HISTORY_LOCK_BYTES + 1);
    let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await descriptor.read(buffer, offset, buffer.length - offset, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    const after = await descriptor.stat();
    if (!sameFileIdentity(after, opened) || after.size !== before.size || offset !== before.size || offset > MAX_HISTORY_LOCK_BYTES) {
      return undefined;
    }
    await assertFilePathIdentityChain(context.lockPath, lockChain);
    return decodeOwner(buffer.subarray(0, offset));
  } catch {
    return undefined;
  } finally {
    await descriptor?.close().catch(() => undefined);
  }
}

async function closeContext(context: LockContext): Promise<void> {
  await context.directory?.close().catch(() => undefined);
  context.directory = undefined;
}

export type HistoryWriteLockLease = {
  readonly lockPath: string;
  readonly ownerToken: string;
  release(): Promise<void>;
};

async function createLease(context: LockContext, ownerToken: string, acquiredAt: number): Promise<HistoryWriteLockLease | undefined> {
  await assertFilePathIdentityChain(context.parent, context.parentChain);
  await assertStoragePathContract(context.parent, context.parentChain);
  const payload = encodePayload({
    schemaVersion: HISTORY_LOCK_SCHEMA_VERSION,
    owner: ownerToken,
    pid: process.pid,
    acquiredAt,
  });

  let descriptor: DirectoryHandle | undefined;
  try {
    descriptor = await open(context.createPath, lockCreateFlags, 0o600);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') return undefined;
    throw new HistoryWriteLockError('history_lock_unavailable', error);
  }

  try {
    const result = await descriptor.write(payload, 0, payload.byteLength, 0);
    if (result.bytesWritten !== payload.byteLength) throw new Error('short_history_lock_write');
    await descriptor.sync();
  } catch (error) {
    throw new HistoryWriteLockError('history_lock_unavailable', error);
  } finally {
    await descriptor.close().catch(() => undefined);
    descriptor = undefined;
  }

  let lockChain: FilePathIdentityChain;
  try {
    await assertFilePathIdentityChain(context.parent, context.parentChain);
    lockChain = await captureFilePathIdentityChain(context.lockPath);
    if (lockChain[lockChain.length - 1]?.[0] !== context.lockPath) throw new Error('history_lock_missing');
  } catch (error) {
    throw new HistoryWriteLockError('history_lock_unavailable', error);
  }

  let releasePromise: Promise<void> | undefined;
  const release = (): Promise<void> => {
    // Assign synchronously before entering the first await. Every concurrent
    // caller therefore shares one ownership check, one unlink, and one close.
    if (releasePromise !== undefined) return releasePromise;
    releasePromise = (async () => {
      try {
        // The identity and payload checks happen immediately before unlink.
        // A changed or malformed lock is never treated as ours.
        await assertFilePathIdentityChain(context.lockPath, lockChain);
        const currentOwner = await readOwner(context, lockChain);
        if (currentOwner !== ownerToken) {
          throw new HistoryWriteLockError('history_lock_not_owned');
        }
        await assertFilePathIdentityChain(context.parent, context.parentChain);
        await assertStoragePathContract(context.parent, context.parentChain);
        await unlink(context.releasePath);
        await context.afterUnlink?.();
      } catch (error) {
        if (error instanceof HistoryWriteLockError) throw error;
        throw new HistoryWriteLockError('history_lock_not_owned', error);
      } finally {
        await closeContext(context);
      }
    })();
    return releasePromise;
  };

  return {
    lockPath: context.lockPath,
    ownerToken,
    release,
  };
}

function lockUnavailable(error: unknown): HistoryWriteLockError {
  return error instanceof HistoryWriteLockError
    ? error
    : new HistoryWriteLockError('history_lock_unavailable', error);
}

function readMonotonicClock(clock: () => number): number {
  const value = clock();
  if (!Number.isFinite(value)) throw new HistoryWriteLockError('history_lock_unavailable');
  return value;
}

/**
 * Acquire a per-history lock. Existing locks are never aged out or deleted:
 * an orphan therefore fails closed until the stopped writer is explicitly
 * recovered by an operator or test that owns the storage boundary.
 */
export async function acquireHistoryWriteLock(
  historyFile: string,
  options: HistoryWriteLockOptions = {},
): Promise<HistoryWriteLockLease> {
  const deadlineMs = validateDuration(options.deadlineMs, HISTORY_LOCK_DEFAULT_DEADLINE_MS, 60_000);
  const pollIntervalMs = validatePollInterval(options.pollIntervalMs);
  const monotonicNow = options.monotonicNow ?? options.now ?? (() => performance.now());
  const sleep = options.sleep ?? ((milliseconds: number) => new Promise<void>(resolveSleep => {
    setTimeout(resolveSleep, milliseconds);
  }));
  const ownerToken = options.ownerToken ?? randomUUID();
  if (!isOwnerToken(ownerToken)) throw new RangeError('invalid_history_lock_owner');

  const startedAt = readMonotonicClock(monotonicNow);
  const deadlineAt = startedAt + deadlineMs;
  const maxAttempts = Math.max(1, Math.ceil(deadlineMs / pollIntervalMs) + 1);
  let attempts = 0;
  let context: LockContext | undefined;
  try {
    context = await prepareLockContext(historyFile, options.afterUnlink);
  } catch (error) {
    // Preparation includes mkdir and storage/path identity checks. Normalize
    // their filesystem failures at the acquisition boundary while leaving the
    // argument validation above as RangeErrors.
    throw lockUnavailable(error);
  }

  const lockContext = context;
  try {
    // Filesystem operations below are intentionally not cancelled. If one is
    // still pending when the monotonic deadline expires, it completes and its
    // descriptor/context is closed before the caller receives the failure.
    if (readMonotonicClock(monotonicNow) >= deadlineAt) {
      await closeContext(lockContext);
      throw new HistoryWriteLockError('history_lock_timeout');
    }
    while (attempts < maxAttempts) {
      attempts += 1;
      if (readMonotonicClock(monotonicNow) >= deadlineAt) {
        throw new HistoryWriteLockError('history_lock_timeout');
      }
      let lease: HistoryWriteLockLease | undefined;
      try {
        lease = await createLease(lockContext, ownerToken, Date.now());
      } catch (error) {
        throw lockUnavailable(error);
      }
      if (lease !== undefined) {
        if (readMonotonicClock(monotonicNow) >= deadlineAt) {
          try {
            await lease.release();
          } catch (error) {
            throw lockUnavailable(error);
          }
          throw new HistoryWriteLockError('history_lock_timeout');
        }
        return lease;
      }
      await options.onContention?.(attempts);
      const current = readMonotonicClock(monotonicNow);
      if (current >= deadlineAt || attempts >= maxAttempts) {
        throw new HistoryWriteLockError('history_lock_timeout');
      }
      const remaining = Math.max(1, Math.min(pollIntervalMs, deadlineAt - current));
      await sleep(remaining);
    }
    throw new HistoryWriteLockError('history_lock_timeout');
  } catch (error) {
    await closeContext(lockContext);
    throw error;
  }
}

export async function withHistoryWriteLock<T>(
  historyFile: string,
  operation: () => Promise<T>,
  options?: HistoryWriteLockOptions,
): Promise<T> {
  const lease = await acquireHistoryWriteLock(historyFile, options);
  try {
    return await operation();
  } finally {
    await lease.release();
  }
}
