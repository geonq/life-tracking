import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { UsageHistoryEntry, type UsageHistoryEntry as Entry } from '@iphone-life-os/contracts';

export class UsageHistory {
  constructor(
    private readonly file: string,
    private readonly maxSamples = 500,
    private readonly maxAgeMs = 30 * 24 * 60 * 60_000,
    /** Injected for deterministic retention tests; production defaults to the system clock. */
    private readonly now: () => number = () => Date.now(),
  ) {}

  async add(entry: Entry): Promise<void> {
    const safe = UsageHistoryEntry.parse(entry);
    const now = this.now();
    const entries = await this.list();
    const next = [...entries, safe]
      .filter(item => now - Date.parse(item.observedAt) <= this.maxAgeMs)
      .sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt))
      .slice(-this.maxSamples);
    await mkdir(dirname(this.file), { recursive: true });
    const temporary = `${this.file}.tmp-${process.pid}-${Date.now()}`;
    await writeFile(temporary, next.map(entry => JSON.stringify(entry)).join('\n') + (next.length ? '\n' : ''), { encoding: 'utf8', mode: 0o600 });
    await rename(temporary, this.file);
  }

  async list(provider?: Entry['provider'], durationMinutes?: number): Promise<Entry[]> {
    let text: string;
    try { text = await readFile(this.file, 'utf8'); } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
      return [];
    }
    try {
      return text.split(/\r?\n/).filter(Boolean).map(line => UsageHistoryEntry.parse(JSON.parse(line)))
        .filter(item => (!provider || item.provider === provider) && (!durationMinutes || item.durationMinutes === durationMinutes))
        .filter(item => this.now() - Date.parse(item.observedAt) <= this.maxAgeMs)
        .sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt)).slice(-this.maxSamples);
    } catch {
      return [];
    }
  }
}
