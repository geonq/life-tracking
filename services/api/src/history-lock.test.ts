import { EventEmitter } from 'node:events';
import { spawn, type ChildProcess } from 'node:child_process';
import { lstat, mkdir, readFile, readdir, rm, stat, symlink, unlink, writeFile } from 'node:fs/promises';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { UsageHistoryEntry } from '@iphone-life-os/contracts';
import { UsageHistory, UsageHistoryError } from './history.js';
import {
  acquireHistoryWriteLock,
  withHistoryWriteLock,
} from './history-lock.js';

const timestamp = (minute: number) => new Date(Date.UTC(2026, 0, 1, 0, minute)).toISOString();
const entry = (minute: number, usedPercent: number): UsageHistoryEntry => ({
  provider: 'codex',
  window: 'five_hour',
  durationMinutes: 300,
  usedPercent,
  observedAt: timestamp(minute),
});
const repositoryRoot = resolve(fileURLToPath(new URL('../../..', import.meta.url)));
const historyModule = new URL('./history.ts', import.meta.url).href;
const lockModule = new URL('./history-lock.ts', import.meta.url).href;

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolvePromise!: (value: T) => void;
  const promise = new Promise<T>(resolveValue => { resolvePromise = resolveValue; });
  return { promise, resolve: resolvePromise };
}

const CHILD_READY_TIMEOUT_MS = 5_000;
const CHILD_EXIT_TIMEOUT_MS = 2_000;

type ConfirmedChildExit = {
  confirmed: true;
  code: number | null;
  signal: NodeJS.Signals | null;
};

type UnconfirmedChildExit = {
  confirmed: false;
  reason: 'spawn_error' | 'timeout';
  error?: Error;
};

type ChildExitResult = ConfirmedChildExit | UnconfirmedChildExit;

type ExitTracker = {
  closed?: ConfirmedChildExit;
  error?: Error;
  waiters: Set<() => void>;
};

type WaitTimer = {
  set(callback: () => void, timeoutMs: number): unknown;
  clear(handle: unknown): void;
};

type WaitForExitOptions = {
  timer?: WaitTimer;
};

type StopChildOptions = {
  waitForExit?: (child: ChildProcess, timeoutMs: number) => Promise<ChildExitResult>;
};

type CleanupOptions = {
  stopChild?: (child: ChildProcess) => Promise<ChildExitResult>;
};

const realWaitTimer: WaitTimer = {
  set: (callback, timeoutMs) => setTimeout(callback, timeoutMs),
  clear: handle => clearTimeout(handle as ReturnType<typeof setTimeout>),
};
const childExitTrackers = new WeakMap<ChildProcess, ExitTracker>();

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function trackChild(child: ChildProcess): ExitTracker {
  const existing = childExitTrackers.get(child);
  if (existing !== undefined) return existing;
  const tracker: ExitTracker = { waiters: new Set() };
  const notify = () => {
    for (const waiter of tracker.waiters) waiter();
  };
  child.once('close', (code, signal) => {
    tracker.closed = { confirmed: true, code, signal };
    notify();
  });
  child.once('error', error => {
    // An error can describe a failed spawn or kill without proving that the
    // process has stopped. Keep waiting for close and let the bounded wait
    // report this as unconfirmed if close never arrives.
    tracker.error = asError(error);
    notify();
  });
  childExitTrackers.set(child, tracker);
  return tracker;
}

function spawnChild(script: string, stdio: ('pipe' | 'ignore')[] = ['ignore', 'pipe', 'pipe']): ChildProcess {
  const child = spawn(process.execPath, ['--import', 'tsx/esm', '--input-type=module', '-e', script], {
    cwd: repositoryRoot,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
    stdio,
  });
  trackChild(child);
  return child;
}

function waitForExit(
  child: ChildProcess,
  timeoutMs = CHILD_EXIT_TIMEOUT_MS,
  options: WaitForExitOptions = {},
): Promise<ChildExitResult> {
  const tracker = trackChild(child);
  if (tracker.closed !== undefined) return Promise.resolve(tracker.closed);
  const timer = options.timer ?? realWaitTimer;
  return new Promise(resolveExit => {
    let settled = false;
    let timeoutHandle: unknown;
    const finish = (result: ChildExitResult) => {
      if (settled) return;
      settled = true;
      if (timeoutHandle !== undefined) timer.clear(timeoutHandle);
      tracker.waiters.delete(check);
      resolveExit(result);
    };
    const check = () => {
      if (tracker.closed !== undefined) finish(tracker.closed);
    };
    tracker.waiters.add(check);
    timeoutHandle = timer.set(() => finish(
      tracker.error === undefined
        ? { confirmed: false, reason: 'timeout' }
        : { confirmed: false, reason: 'spawn_error', error: tracker.error },
    ), timeoutMs);
    check();
  });
}

class ChildTerminationError extends Error {
  readonly attempts: readonly ChildExitResult[];
  readonly killErrors: readonly Error[];

  constructor(attempts: readonly ChildExitResult[], killErrors: readonly Error[] = []) {
    super('child_exit_unconfirmed_after_sigkill');
    this.name = 'ChildTerminationError';
    this.attempts = attempts;
    this.killErrors = killErrors;
  }
}

async function stopChild(child: ChildProcess, options: StopChildOptions = {}): Promise<ConfirmedChildExit> {
  const wait = options.waitForExit ?? ((candidate: ChildProcess, timeoutMs: number) => waitForExit(candidate, timeoutMs));
  const attempts: ChildExitResult[] = [];
  const killErrors: Error[] = [];
  const observe = async (timeoutMs: number): Promise<ChildExitResult> => {
    try {
      return await wait(child, timeoutMs);
    } catch (error) {
      return { confirmed: false, reason: 'spawn_error', error: asError(error) };
    }
  };
  const alreadyExited = await observe(1);
  attempts.push(alreadyExited);
  if (alreadyExited.confirmed) return alreadyExited;

  try {
    if (!child.kill('SIGTERM')) killErrors.push(new Error('sigterm_not_sent'));
  } catch (error) {
    killErrors.push(asError(error));
  }
  const terminated = await observe(CHILD_EXIT_TIMEOUT_MS);
  attempts.push(terminated);
  if (terminated.confirmed) return terminated;

  try {
    if (!child.kill('SIGKILL')) killErrors.push(new Error('sigkill_not_sent'));
  } catch (error) {
    killErrors.push(asError(error));
  }
  const killed = await observe(CHILD_EXIT_TIMEOUT_MS);
  attempts.push(killed);
  if (killed.confirmed) return killed;
  throw new ChildTerminationError(attempts, killErrors);
}

async function cleanupChildrenAndStorage(
  directory: string,
  children: readonly ChildProcess[],
  lockPaths: readonly string[] = [],
  options: CleanupOptions = {},
): Promise<void> {
  const stop = options.stopChild ?? (child => stopChild(child));
  const childResults = await Promise.allSettled(children.map(async child => {
    const result = await stop(child);
    if (!result.confirmed) throw new ChildTerminationError([result]);
    return result;
  }));
  const childFailures = childResults.flatMap(result => result.status === 'rejected' ? [result.reason] : []);
  if (childFailures.length > 0) {
    throw new AggregateError(childFailures, 'child_cleanup_unconfirmed');
  }

  const lockResults = await Promise.allSettled(lockPaths.map(lockPath => rm(lockPath, { force: true })));
  const lockFailures = lockResults.flatMap(result => result.status === 'rejected' ? [result.reason] : []);
  if (lockFailures.length > 0) {
    throw new AggregateError(lockFailures, 'lock_cleanup_failed');
  }

  await rm(directory, { recursive: true, force: true });
}

function captureOutput(child: ChildProcess): { text: () => string; waitFor: (needle: string, timeoutMs?: number) => Promise<void> } {
  let output = '';
  let closed: ConfirmedChildExit | undefined;
  const waiters = new Set<() => void>();
  child.stdout?.on('data', chunk => {
    output += String(chunk);
    for (const resolveWaiter of waiters) resolveWaiter();
  });
  child.once('close', (code, signal) => {
    closed = { confirmed: true, code, signal };
    for (const resolveWaiter of waiters) resolveWaiter();
  });
  return {
    text: () => output,
    waitFor: (needle, timeoutMs = CHILD_READY_TIMEOUT_MS) => new Promise<void>((resolveNeedle, rejectNeedle) => {
      if (output.includes(needle)) {
        resolveNeedle();
        return;
      }
      if (closed !== undefined) {
        rejectNeedle(new Error(`child_closed_before_${needle}_code=${closed.code}_signal=${closed.signal} output=${output}`));
        return;
      }
      let timer: ReturnType<typeof setTimeout> | undefined;
      const check = () => {
        if (output.includes(needle)) {
          if (timer !== undefined) clearTimeout(timer);
          waiters.delete(check);
          resolveNeedle();
        } else if (closed !== undefined) {
          if (timer !== undefined) clearTimeout(timer);
          waiters.delete(check);
          rejectNeedle(new Error(`child_closed_before_${needle}_code=${closed.code}_signal=${closed.signal} output=${output}`));
        }
      };
      waiters.add(check);
      timer = setTimeout(() => {
        waiters.delete(check);
        rejectNeedle(new Error(`child_output_timeout needle=${needle} output=${output}`));
      }, timeoutMs);
    }),
  };
}

class FakeChildProcess extends EventEmitter {
  readonly signals: NodeJS.Signals[] = [];

  kill(signal?: NodeJS.Signals): boolean {
    if (signal !== undefined) this.signals.push(signal);
    return true;
  }
}

function holderScript(file: string): string {
  return `
    import { acquireHistoryWriteLock } from ${JSON.stringify(lockModule)};
    await acquireHistoryWriteLock(${JSON.stringify(file)}, { ownerToken: 'orphan-owner' });
    process.stdout.write('locked\\n');
    setInterval(() => {}, 1000);
  `;
}

function barrierHolderScript(file: string): string {
  return `
    import { createInterface } from 'node:readline';
    import { UsageHistory } from ${JSON.stringify(historyModule)};
    import { acquireHistoryWriteLock } from ${JSON.stringify(lockModule)};
    const lease = await acquireHistoryWriteLock(${JSON.stringify(file)}, { ownerToken: 'barrier-holder' });
    process.stdout.write('lock-held\\n');
    const control = createInterface({ input: process.stdin });
    await new Promise(resolve => control.once('line', resolve));
    await lease.release();
    control.close();
    process.stdout.write('lock-released\\n');
    const store = new UsageHistory(${JSON.stringify(file)}, 100, 7200000, () => Date.parse(${JSON.stringify(timestamp(10))}));
    const outcome = await store.add({ ...${JSON.stringify(entry(0, 10))}, window: 'five_hour', durationMinutes: 300 }, 'child-a');
    process.stdout.write('result:' + JSON.stringify(outcome) + '\\n');
  `;
}

function barrierWriterScript(file: string): string {
  return `
    import { UsageHistory } from ${JSON.stringify(historyModule)};
    const store = new UsageHistory(${JSON.stringify(file)}, 100, 7200000, () => Date.parse(${JSON.stringify(timestamp(10))}), {
      onContention: () => process.stdout.write('lock-contention\\n'),
    });
    const outcome = await store.add({ ...${JSON.stringify(entry(1, 20))}, window: 'seven_day', durationMinutes: 10080 }, 'child-b');
    process.stdout.write('result:' + JSON.stringify(outcome) + '\\n');
  `;
}

describe('history write lock', () => {
  it('serializes two real API child processes and preserves distinct revisions', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-processes-'));
    const file = join(directory, 'nested', 'history.jsonl');
    const holder = spawnChild(barrierHolderScript(file), ['pipe', 'pipe', 'pipe']);
    const holderOutput = captureOutput(holder);
    const children: ChildProcess[] = [holder];
    try {
      await holderOutput.waitFor('lock-held');
      const writer = spawnChild(barrierWriterScript(file));
      children.push(writer);
      const writerOutput = captureOutput(writer);
      await writerOutput.waitFor('lock-contention');
      holder.stdin?.write('\n');
      await holderOutput.waitFor('lock-released');
      const [holderExit, writerExit] = await Promise.all([
        waitForExit(holder, CHILD_EXIT_TIMEOUT_MS),
        waitForExit(writer, CHILD_EXIT_TIMEOUT_MS),
      ]);
      if (!holderExit.confirmed || !writerExit.confirmed || holderExit.code !== 0 || writerExit.code !== 0) {
        throw new Error(`barrier_child_exit holder=${JSON.stringify(holderExit)} writer=${JSON.stringify(writerExit)}`);
      }
      const holderResult = holderOutput.text().split('\n').find(line => line.startsWith('result:'));
      const writerResult = writerOutput.text().split('\n').find(line => line.startsWith('result:'));
      if (holderResult === undefined || writerResult === undefined) throw new Error('barrier_result_missing');
      const outcomes = [JSON.parse(holderResult.slice('result:'.length)), JSON.parse(writerResult.slice('result:'.length))] as Array<{ kind: string; revision: number }>;
      expect(outcomes.map(outcome => outcome.kind).sort()).toEqual(['accepted', 'accepted']);
      expect(outcomes.map(outcome => outcome.revision).sort((a, b) => a - b)).toEqual([1, 2]);

      const store = new UsageHistory(file, 100, 7_200_000, () => Date.parse(timestamp(10)));
      expect((await store.list()).map(item => item.usedPercent)).toEqual([10, 20]);
      const state = JSON.parse(await readFile(`${file}.state.json`, 'utf8')) as {
        metadata: { revision: number; idempotency: Array<{ key: string; revision: number }> };
      };
      expect(state.metadata.revision).toBe(2);
      expect(state.metadata.idempotency.map(record => record.key).sort()).toEqual(['child-a', 'child-b']);
      expect(state.metadata.idempotency.map(record => record.revision).sort((a, b) => a - b)).toEqual([1, 2]);
      expect((await readdir(dirname(file))).filter(name => name.endsWith('.lock'))).toEqual([]);
    } finally {
      await cleanupChildrenAndStorage(directory, children, [`${file}.lock`]);
    }
  });

  it('waits for an owned writer and succeeds before the injected deadline', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-contention-'));
    const file = join(directory, 'history.jsonl');
    const acquired = deferred<void>();
    const release = deferred<void>();
    try {
      const first = withHistoryWriteLock(file, async () => {
        acquired.resolve();
        await release.promise;
        return 'first';
      }, { ownerToken: 'holder-one' });
      await acquired.promise;

      let sleeps = 0;
      const second = withHistoryWriteLock(file, async () => 'second', {
        ownerToken: 'waiter-two',
        deadlineMs: 1_000,
        pollIntervalMs: 10,
        sleep: async milliseconds => {
          sleeps += 1;
          await new Promise<void>(resolveSleep => { setTimeout(resolveSleep, milliseconds); });
        },
      });
      await new Promise<void>(resolveSleep => { setTimeout(resolveSleep, 40); });
      release.resolve();
      await expect(first).resolves.toBe('first');
      await expect(second).resolves.toBe('second');
      expect(sleeps).toBeGreaterThan(0);
      expect(await readdir(directory)).not.toContain('history.jsonl.lock');
    } finally {
      release.resolve();
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('memoizes concurrent release calls and never removes a successor lock', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-release-race-'));
    const file = join(directory, 'history.jsonl');
    const afterUnlink = deferred<void>();
    let successor: Awaited<ReturnType<typeof acquireHistoryWriteLock>> | undefined;
    const lease = await acquireHistoryWriteLock(file, {
      ownerToken: 'release-owner',
      afterUnlink: () => afterUnlink.promise,
    });
    try {
      const firstRelease = lease.release();
      const secondRelease = lease.release();
      expect(secondRelease).toBe(firstRelease);

      // The first release has unlinked the original identity but remains
      // pending in afterUnlink, so this is a real successor acquisition while
      // the original release promise is still unresolved.
      successor = await acquireHistoryWriteLock(file, { ownerToken: 'successor-owner' });
      expect(await readFile(`${file}.lock`, 'utf8')).toContain('successor-owner');
      afterUnlink.resolve();
      await firstRelease;
      expect(await readFile(`${file}.lock`, 'utf8')).toContain('successor-owner');
    } finally {
      afterUnlink.resolve();
      await lease.release().catch(() => undefined);
      await successor?.release().catch(() => undefined);
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('times out without changing state when the lock remains held', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-timeout-'));
    const file = join(directory, 'history.jsonl');
    const holder = await acquireHistoryWriteLock(file, { ownerToken: 'holder-timeout' });
    let clock = 0;
    let sleeps = 0;
    try {
      await expect(acquireHistoryWriteLock(file, {
        ownerToken: 'waiter-timeout',
        deadlineMs: 30,
        pollIntervalMs: 10,
        now: () => clock,
        sleep: async milliseconds => {
          sleeps += 1;
          clock += milliseconds;
        },
      })).rejects.toMatchObject({
        code: 'storage_unavailable',
        reason: 'history_lock_timeout',
      });
      expect(sleeps).toBeGreaterThan(0);
      await expect(stat(file)).rejects.toMatchObject({ code: 'ENOENT' });
      expect(await readdir(directory)).toContain('history.jsonl.lock');
    } finally {
      await holder.release();
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('checks the monotonic deadline before retrying after an overslept poll', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-oversleep-'));
    const file = join(directory, 'history.jsonl');
    const holder = await acquireHistoryWriteLock(file, { ownerToken: 'oversleep-holder' });
    let clock = 0;
    let contention = 0;
    try {
      await expect(acquireHistoryWriteLock(file, {
        ownerToken: 'oversleep-waiter',
        deadlineMs: 20,
        pollIntervalMs: 10,
        monotonicNow: () => clock,
        onContention: () => { contention += 1; },
        sleep: async () => { clock = 100; },
      })).rejects.toMatchObject({
        code: 'storage_unavailable',
        reason: 'history_lock_timeout',
      });
      expect(contention).toBe(1);
      expect(await readFile(`${file}.lock`, 'utf8')).toContain('oversleep-holder');
    } finally {
      await holder.release();
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('includes slow preparation in the monotonic deadline and never runs the operation', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-slow-prepare-'));
    const file = join(directory, 'history.jsonl');
    let clockReads = 0;
    let operationRan = false;
    try {
      await expect(withHistoryWriteLock(file, async () => {
        operationRan = true;
      }, {
        ownerToken: 'slow-preparation',
        deadlineMs: 50,
        monotonicNow: () => {
          clockReads += 1;
          return clockReads === 1 ? 0 : 100;
        },
      })).rejects.toMatchObject({
        code: 'storage_unavailable',
        reason: 'history_lock_timeout',
      });
      expect(clockReads).toBeGreaterThanOrEqual(2);
      expect(operationRan).toBe(false);
      await expect(stat(`${file}.lock`)).rejects.toMatchObject({ code: 'ENOENT' });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('releases a lease acquired after the post-create deadline and skips the operation', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-post-create-deadline-'));
    const file = join(directory, 'history.jsonl');
    let clockReads = 0;
    let operationRan = false;
    try {
      await expect(withHistoryWriteLock(file, async () => {
        operationRan = true;
      }, {
        ownerToken: 'post-create-deadline',
        deadlineMs: 50,
        monotonicNow: () => {
          clockReads += 1;
          return clockReads <= 3 ? 0 : 100;
        },
      })).rejects.toMatchObject({
        code: 'storage_unavailable',
        reason: 'history_lock_timeout',
      });
      expect(operationRan).toBe(false);
      expect(clockReads).toBeGreaterThanOrEqual(4);
      await expect(stat(`${file}.lock`)).rejects.toMatchObject({ code: 'ENOENT' });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('keeps storage when child termination is unconfirmed after an error and SIGKILL', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-unconfirmed-cleanup-'));
    const marker = join(directory, 'retain-me.txt');
    await writeFile(marker, 'retain storage', { mode: 0o600 });
    const fake = new FakeChildProcess();
    const child = fake as unknown as ChildProcess;
    try {
      const pendingExit = waitForExit(child, 1, {
        timer: {
          set: callback => {
            queueMicrotask(callback);
            return undefined;
          },
          clear: () => undefined,
        },
      });
      fake.emit('error', new Error('spawn failed'));
      await expect(pendingExit).resolves.toMatchObject({ confirmed: false, reason: 'spawn_error' });

      await expect(stopChild(child, {
        waitForExit: async () => ({ confirmed: false, reason: 'timeout' }),
      })).rejects.toBeInstanceOf(ChildTerminationError);
      expect(fake.signals).toEqual(['SIGTERM', 'SIGKILL']);

      await expect(cleanupChildrenAndStorage(directory, [child], [], {
        stopChild: async () => ({ confirmed: false, reason: 'timeout' }),
      })).rejects.toBeInstanceOf(AggregateError);
      expect((await stat(directory)).isDirectory()).toBe(true);
      expect(await readFile(marker, 'utf8')).toBe('retain storage');
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('refuses to release a lock whose owner token changed', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-owner-'));
    const file = join(directory, 'history.jsonl');
    const lockPath = `${file}.lock`;
    const lease = await acquireHistoryWriteLock(file, { ownerToken: 'owner-alpha' });
    try {
      const payload = JSON.parse(await readFile(lockPath, 'utf8')) as Record<string, unknown>;
      payload.owner = 'owner-bravo';
      await writeFile(lockPath, JSON.stringify(payload), { mode: 0o600 });
      await expect(lease.release()).rejects.toMatchObject({
        code: 'storage_unavailable',
        reason: 'history_lock_not_owned',
      });
      expect(await readFile(lockPath, 'utf8')).toContain('owner-bravo');
    } finally {
      await unlink(lockPath).catch(() => undefined);
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('maps an invalid regular-file parent to UsageHistory storage_unavailable', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-invalid-parent-'));
    const regularParent = join(directory, 'regular-parent');
    const file = join(regularParent, 'history.jsonl');
    await writeFile(regularParent, 'not a directory', { mode: 0o600 });
    try {
      const store = new UsageHistory(file, 100, 7_200_000, () => Date.parse(timestamp(10)));
      await expect(store.add(entry(0, 10))).rejects.toBeInstanceOf(UsageHistoryError);
      await expect(store.add(entry(0, 10))).rejects.toMatchObject({ code: 'storage_unavailable' });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('does not follow a pre-planted lock symlink or change its victim', async () => {
    if (process.platform === 'win32') return;
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-lock-symlink-'));
    const file = join(directory, 'nested', 'history.jsonl');
    const lockPath = `${file}.lock`;
    const victim = join(directory, 'victim.txt');
    try {
      await mkdir(dirname(file), { recursive: true, mode: 0o700 });
      await writeFile(victim, 'victim bytes', { mode: 0o600 });
      await symlink(victim, lockPath);
      let clock = 0;
      await expect(acquireHistoryWriteLock(file, {
        ownerToken: 'symlink-test',
        deadlineMs: 20,
        pollIntervalMs: 10,
        now: () => clock,
        sleep: async milliseconds => { clock += milliseconds; },
      })).rejects.toMatchObject({ reason: 'history_lock_timeout' });
      expect(await readFile(victim, 'utf8')).toBe('victim bytes');
      expect((await lstat(lockPath)).isSymbolicLink()).toBe(true);
    } finally {
      await unlink(lockPath).catch(() => undefined);
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('does not silently steal an orphaned lock after its child owner is killed', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'lifeos-history-orphan-'));
    const file = join(directory, 'history.jsonl');
    const lockPath = `${file}.lock`;
    const child = spawnChild(holderScript(file));
    const output = captureOutput(child);
    try {
      await output.waitFor('locked');
      const childExit = await stopChild(child);
      expect(childExit.confirmed).toBe(true);
      let clock = 0;
      await expect(acquireHistoryWriteLock(file, {
        ownerToken: 'new-owner',
        deadlineMs: 30,
        pollIntervalMs: 10,
        monotonicNow: () => clock,
        sleep: async milliseconds => { clock += milliseconds; },
      })).rejects.toMatchObject({
        code: 'storage_unavailable',
        reason: 'history_lock_timeout',
      });
      expect(await readFile(lockPath, 'utf8')).toContain('orphan-owner');
    } finally {
      await cleanupChildrenAndStorage(directory, [child], [lockPath]);
    }
  });
});
