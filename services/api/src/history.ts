import { randomUUID } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { mkdir, lstat, open, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { UsageHistoryEntry, type UsageHistoryEntry as Entry } from '@iphone-life-os/contracts';

/** Keep malformed or unexpectedly large history files from causing an unbounded allocation. */
export const MAX_HISTORY_BYTES = 1 * 1024 * 1024;
const HISTORY_OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);

export class UsageHistory {
  private static readonly writeQueues = new Map<string, Promise<void>>();
  private readonly file: string;

  constructor(
    file: string,
    private readonly maxSamples = 500,
    private readonly maxAgeMs = 30 * 24 * 60 * 60_000,
    /** Injected for deterministic retention tests; production defaults to the system clock. */
    private readonly now: () => number = () => Date.now(),
  ) {
    // history() creates a new instance per request, so the resolved path is the queue key.
    this.file = resolve(file);
  }

  async add(entry: Entry): Promise<void> {
    return this.addMany([entry]);
  }

  async addMany(entries: readonly Entry[]): Promise<void> {
    // Parse the complete batch before entering the queue: one invalid item cannot result in
    // a partial write of an otherwise valid batch.
    const safe = entries.map(entry => UsageHistoryEntry.parse(entry));
    if (!safe.length) return;
    return this.enqueue(async () => {
      const existing = await this.readStrict();
      const nextEntries = [...existing];
      for (const incoming of safe) {
        const latest = nextEntries
          .filter(item => item.provider === incoming.provider && item.window === incoming.window)
          .reduce<Entry | undefined>((current, item) => !current || Date.parse(item.observedAt) > Date.parse(current.observedAt) ? item : current, undefined);
        const sameValues = latest?.usedPercent === incoming.usedPercent && latest?.resetAt === incoming.resetAt;
        // Replaying the same provider/window observation is always idempotent. A
        // statusline may be retried well after the previous request, so elapsed
        // time must not turn an identical observation into a duplicate sample.
        if (latest !== undefined && sameValues) continue;
        // A delayed collector retry must never become the apparent current
        // observation. This is deliberately per provider/window: a reset or a
        // changed value is useful only when it was captured after the latest
        // sample for that same quota window.
        if (latest !== undefined && Date.parse(incoming.observedAt) <= Date.parse(latest.observedAt)) continue;
        nextEntries.push(incoming);
      }

      // A fully deduplicated retry must not rewrite the file (or update its mtime).
      if (nextEntries.length === existing.length) return;

      const now = this.now();
      const retained = nextEntries
        .filter(item => now - Date.parse(item.observedAt) <= this.maxAgeMs)
        .sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt))
        .slice(-this.maxSamples);
      await mkdir(dirname(this.file), { recursive: true });
      const temporary = `${this.file}.tmp-${process.pid}-${randomUUID()}`;
      try {
        await writeFile(temporary, retained.map(entry => JSON.stringify(entry)).join('\n') + (retained.length ? '\n' : ''), {
          encoding: 'utf8', mode: 0o600,
        });
        await rename(temporary, this.file);
      } finally {
        await unlink(temporary).catch(() => undefined);
      }
    });
  }

  async list(provider?: Entry['provider'], durationMinutes?: number): Promise<Entry[]> {
    // A corrupt or unexpectedly replaced store is an availability failure,
    // not an empty history. Callers must preserve that distinction.
    const entries = await this.readStrict();
    return entries
      .filter(item => (!provider || item.provider === provider) && (!durationMinutes || item.durationMinutes === durationMinutes))
      .filter(item => this.now() - Date.parse(item.observedAt) <= this.maxAgeMs)
      .sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt))
      .slice(-this.maxSamples);
  }

  /** Read/validate the configured store without creating or replacing it. */
  async ready(): Promise<boolean> {
    try {
      await this.readStrict();
      return true;
    } catch {
      return false;
    }
  }

  private async readStrict(): Promise<Entry[]> {
    let descriptor: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const before = await lstat(this.file);
      if (!before.isFile() || before.isSymbolicLink() || before.size > MAX_HISTORY_BYTES) throw new Error('history_unavailable');
      descriptor = await open(this.file, HISTORY_OPEN_FLAGS);
      const opened = await descriptor.stat();
      if (!opened.isFile() || opened.isSymbolicLink()
        || opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size) {
        throw new Error('history_unavailable');
      }
      const buffer = Buffer.alloc(MAX_HISTORY_BYTES + 1);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesRead } = await descriptor.read(buffer, offset, buffer.length - offset, offset);
        if (bytesRead === 0) break;
        offset += bytesRead;
      }
      const after = await descriptor.stat();
      if (!after.isFile() || after.isSymbolicLink()
        || after.dev !== before.dev || after.ino !== before.ino || after.size !== before.size
        || offset > MAX_HISTORY_BYTES) throw new Error('history_unavailable');
      const text = buffer.subarray(0, offset).toString('utf8');
      return text.split(/\r?\n/).filter(Boolean).map(line => UsageHistoryEntry.parse(JSON.parse(line)));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
      throw error;
    } finally {
      if (descriptor) await descriptor.close().catch(() => undefined);
    }
  }

  private enqueue(task: () => Promise<void>): Promise<void> {
    const previous = UsageHistory.writeQueues.get(this.file) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(task);
    UsageHistory.writeQueues.set(this.file, next);
    return next.finally(() => {
      if (UsageHistory.writeQueues.get(this.file) === next) UsageHistory.writeQueues.delete(this.file);
    });
  }
}
