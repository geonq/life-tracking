import { describe, expect, it } from 'vitest';
import { request } from 'node:http';
import { createApiServer } from './server.js';

describe('HTTP API', () => {
  it('serves health, overview and codex, rejects methods and unknown paths', async () => {
    const server = createApiServer(); await new Promise<void>(r => server.listen(0, r));
    const address = server.address(); if (!address || typeof address === 'string') throw Error('no address');
    const call = (path:string, method='GET') => new Promise<{status:number; body:any}>(resolve => { const req=request({port:address.port,path,method}, res=>{let b='';res.on('data',x=>b+=x);res.on('end',()=>resolve({status:res.statusCode!,body:JSON.parse(b)}))});req.end(); });
    expect((await call('/health')).body.status).toBe('ok'); expect((await call('/api/overview')).body.label).toBe('Demo data'); expect((await call('/api/codex')).body.kind).toBe('codex'); expect((await call('/missing')).status).toBe(404); expect((await call('/health','POST')).status).toBe(405); await new Promise(r=>server.close(r));
  });
});
