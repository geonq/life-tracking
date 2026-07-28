import { describe, expect, it } from 'vitest';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizeWindow, type UsageHistoryEntry } from '@iphone-life-os/contracts';
import { projectUsage } from './projection.js';
import { ingestClaudeStatusline } from './claude-ingest.js';
import { UsageHistory } from './history.js';
const t=(n:number)=>new Date(Date.UTC(2026,0,1,0,n)).toISOString();
const entry=(n:number, usedPercent:number): UsageHistoryEntry => ({provider:'codex',window:'five_hour',durationMinutes:300,usedPercent,observedAt:t(n)});
describe('usage contracts and projection',()=>{
 it('separates providers and marks estimates nonofficial',()=>{const a=normalizeWindow({usedPercentage:20,resetsAt:1700000000},'codex','five_hour','x',t(0)); const b=normalizeWindow({usedPercentage:40,resetsAt:'2026-01-01T05:00:00Z'},'claude','five_hour','x',t(0)); expect(a.provider).not.toBe(b.provider); expect(projectUsage([{...a,usedPercent:20,observedAt:t(0),durationMinutes:300},{...a,usedPercent:30,observedAt:t(5),durationMinutes:300}]).official).toBe(false);});
 it('unavailable windows remain unavailable',()=>expect(normalizeWindow({},'codex','seven_day','x',t(0)).availability).toBe('unavailable'));
 it('normalizes documented Claude shape and strips sensitive fields',()=>{const w=ingestClaudeStatusline({rate_limits:{five_hour:{used_percentage:12,resets_at:'2026-01-01T05:00:00Z',token:'secret'},seven_day:{used_percentage:3,resets_at:'2026-01-08T00:00:00Z'}}},t(0)); expect(w.map(x=>x.usedPercent)).toEqual([12,3]); expect(JSON.stringify(w)).not.toContain('secret');});
 it('does not project decreases, zero velocity, or mixed providers',()=>{const a={provider:'codex' as const,window:'five_hour' as const,durationMinutes:300,usedPercent:20,observedAt:t(0),resetAt:t(300)}; expect(projectUsage([a,{...a,usedPercent:10,observedAt:t(5)}]).confidence).toBe('insufficient'); expect(projectUsage([a,{...a,provider:'claude',usedPercent:30,observedAt:t(5)}]).confidence).toBe('insufficient');});
 it('retains bounded valid history and fails closed on corruption',async()=>{const dir=await mkdtemp(join(tmpdir(),'usage-')); const file=join(dir,'history.jsonl'); const store=new UsageHistory(file,2,60*60*1000,()=>Date.parse(t(2))); await store.add(entry(0,10)); await store.add(entry(1,20)); await store.add(entry(2,30)); expect((await store.list()).map(x=>x.usedPercent)).toEqual([20,30]); const raw=await readFile(file,'utf8'); expect(raw).not.toContain('secret'); await writeFile(file,raw+'not-json\\n'); expect(await store.list()).toEqual([]);});
});
