#!/usr/bin/env node

import { request as httpRequest, type RequestOptions } from 'node:http';
import { fileURLToPath } from 'node:url';
import { isAbsolute, resolve } from 'node:path';
import { parseCodexIngestEnvelope, parseCodexIngestPayload, readCodexAppServer, type CodexLiveResult, type CodexWindow } from './codex-adapter.js';
import { readIngestSecretFile } from './ingest-secret.js';

const COLLECTOR_PORT = 8787;
const COLLECTOR_TIMEOUT_MS = 8_000;
const MAX_RESPONSE_BYTES = 16 * 1024;

type RequestFactory = (options: RequestOptions, callback: (response: import('node:http').IncomingMessage) => void) => import('node:http').ClientRequest;
type CollectorDependencies = {
  read?: () => Promise<CodexLiveResult>;
  post?: (payload: { windows: CodexWindow[]; observedAt?: string }, secret: string) => Promise<void>;
  secret?: () => Promise<string | undefined>;
};

function collectorWindows(result: CodexLiveResult): CodexWindow[] {
  // Re-parse the adapter output at the boundary as a second guard against
  // accidentally adding app-server fields to the wire payload later.
  const windows = result.windows.map(({ minutes, usedPercent, resetAt }) => ({
    minutes, usedPercent, ...(resetAt ? { resetAt } : {}),
  }));
  return parseCodexIngestPayload({ windows });
}

export async function postCodexPayload(
  payload: { windows: CodexWindow[]; observedAt?: string },
  secret: string,
  port = COLLECTOR_PORT,
  requestFactory: RequestFactory = httpRequest,
): Promise<void> {
  const envelope = parseCodexIngestEnvelope(payload);
  const encoded = Buffer.from(JSON.stringify(envelope), 'utf8');
  await new Promise<void>((resolveRequest, rejectRequest) => {
    let settled = false;
    const fail = () => {
      if (settled) return;
      settled = true;
      rejectRequest(new Error('collector_unavailable'));
    };
    const options: RequestOptions = {
      hostname: '127.0.0.1', port, path: '/api/usage/codex-ingest', method: 'POST',
      agent: false,
      headers: {
        authorization: `Bearer ${secret}`,
        'content-type': 'application/json',
        'content-length': encoded.byteLength,
      },
    };
    let req: import('node:http').ClientRequest;
    try {
      req = requestFactory(options, response => {
        let responseBytes = 0;
        response.on('data', chunk => {
          responseBytes += Buffer.byteLength(chunk);
          if (responseBytes > MAX_RESPONSE_BYTES) {
            req.destroy();
            fail();
          }
        });
        response.on('error', fail);
        response.on('end', () => {
          // Do not follow redirects or expose response content. Only a 2xx
          // response from the exact loopback endpoint is success.
          if (!settled && (response.statusCode ?? 0) >= 200 && (response.statusCode ?? 0) < 300) {
            settled = true;
            resolveRequest();
          } else if (!settled) {
            fail();
          }
        });
      });
      req.setTimeout(COLLECTOR_TIMEOUT_MS, () => { req.destroy(); fail(); });
      req.on('error', fail);
      req.end(encoded);
    } catch {
      fail();
    }
  });
}

export async function runCodexCollector(dependencies: CollectorDependencies = {}): Promise<void> {
  const secret = await (dependencies.secret ?? (() => readIngestSecretFile(process.env.CODEX_INGEST_SECRET_FILE)))();
  if (!secret) throw new Error('collector_unavailable');
  const result = await (dependencies.read ?? readCodexAppServer)();
  if (!result.windows.length) throw new Error('collector_unavailable');
  const windows = collectorWindows(result);
  await (dependencies.post ?? ((payload, token) => postCodexPayload(payload, token)))({ windows, ...(result.observedAt ? { observedAt: result.observedAt } : {}) }, secret);
}

function secretFileArgument(argv: string[]): string | undefined {
  if (argv.length === 0) return undefined;
  if (argv.length !== 2 || argv[0] !== '--secret-file' || !isAbsolute(argv[1]!)) {
    throw new Error('collector_unavailable');
  }
  return resolve(argv[1]!);
}

export async function main(): Promise<number> {
  try {
    const secretFile = secretFileArgument(process.argv.slice(2));
    await runCodexCollector({
      // The scheduled task receives only this absolute path. The secret
      // itself remains file-backed and is never placed in task XML/arguments.
      secret: () => readIngestSecretFile(secretFile ?? process.env.CODEX_INGEST_SECRET_FILE),
    });
    process.stdout.write('success\n');
    return 0;
  } catch {
    process.stdout.write('unavailable\n');
    return 1;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  void main().then(code => { process.exitCode = code; });
}
