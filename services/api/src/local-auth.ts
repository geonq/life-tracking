import { createHash, timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import { readIngestSecretFile } from './ingest-secret.js';

/**
 * Local service contract (all modes, including tests):
 * LIFEOS_LOCAL_API_ENABLED=true enables protected routes and requires
 * LIFEOS_LOCAL_API_SECRET_FILE. Setting the file alone also enables them.
 * Explicit false disables the surface (503); it NEVER disables authentication.
 * A malformed flag fails startup/readiness. No inline-secret fallback exists.
 *
 * The file must be absolute, regular, non-symlink, bounded, owner-only on POSIX,
 * and contain 32–256 printable ASCII bytes with no whitespace/newline, matching
 * readIngestSecretFile's descriptor/identity checks. Windows ACL provisioning
 * remains the service installer's responsibility.
 *
 * Gateway callers send exactly one Authorization: Bearer <local-service-secret>
 * on these routes, using loopback. Swift calls the authenticated gateway; this
 * credential must never be shipped to Swift or forwarded from incoming clients.
 * Ingestion retains its own credential; never reuse that value.
 * 401 = missing/invalid bearer, 403 = non-loopback, 503 = disabled/bad config.
 * GET /ready checks configuration without a bearer; /health is public liveness.
 */
export const LOCAL_API_ROUTES = [
  ['GET', '/api/usage'],
  ['GET', '/api/codex/live'],
  ['GET', '/api/clipper/summary'],
  ['POST', '/api/nutrition/photo-proposal'],
  ['POST', '/nutrition/photo-proposal'],
] as const;

export function isLocalApiPath(path: string | undefined): boolean {
  return LOCAL_API_ROUTES.some(([, route]) => route === path);
}

export function requiresLocalApiAuth(method: string | undefined, path: string | undefined): boolean {
  return LOCAL_API_ROUTES.some(([verb, route]) => method === verb && path === route);
}

function localApiEnabled(): boolean {
  return process.env.LIFEOS_LOCAL_API_ENABLED === 'true'
    || (process.env.LIFEOS_LOCAL_API_ENABLED === undefined && process.env.LIFEOS_LOCAL_API_SECRET_FILE !== undefined);
}
function validFlag(): boolean {
  return process.env.LIFEOS_LOCAL_API_ENABLED === undefined
    || ['true', 'false'].includes(process.env.LIFEOS_LOCAL_API_ENABLED);
}
const digest = (value: string) => createHash('sha256').update(value).digest();
export const constantTimeCredentialEqual = (a: string, b: string): boolean => timingSafeEqual(digest(a), digest(b));
const credentialFingerprint = (value: string): string => digest(value).toString('hex');

// Compare values, not paths: different files can contain the same credential.
async function credentials() {
  const paths = [process.env.LIFEOS_LOCAL_API_SECRET_FILE,
    process.env.CODEX_INGEST_SECRET_FILE, process.env.CLAUDE_INGEST_SECRET_FILE,
    process.env.CLIPPER_INGEST_SECRET_FILE];
  const values = await Promise.all(paths.map(readIngestSecretFile));
  const [local] = values;
  const fingerprints = new Set<string>();
  let invalid = false;
  let reused = false;
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (paths[index] !== undefined && value === undefined) invalid = true;
    if (value === undefined) continue;
    const fingerprint = credentialFingerprint(value);
    if (fingerprints.has(fingerprint)) reused = true;
    fingerprints.add(fingerprint);
  }
  return { local, reused: invalid || reused };
}
export async function localApiConfigurationReady(): Promise<boolean> {
  const { local, reused } = await credentials();
  return validFlag() && !reused && (!localApiEnabled() || local !== undefined);
}

export async function authorizeLocalApi(req: IncomingMessage): Promise<401 | 403 | 503 | undefined> {
  if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress ?? '')) return 403;
  if (!validFlag() || !localApiEnabled()) return 503;
  const { local: expected, reused } = await credentials();
  if (!expected || reused) return 503;
  const values: string[] = [];
  // Raw headers are authoritative: Node can silently discard duplicate Authorization.
  if (req.rawHeaders?.length) {
    for (let i = 0; i < req.rawHeaders.length; i += 2)
      if (req.rawHeaders[i]?.toLowerCase() === 'authorization') values.push(req.rawHeaders[i + 1] ?? '');
  } else {
    const value = req.headers.authorization;
    if (Array.isArray(value)) values.push(...value);
    else if (value !== undefined) values.push(value);
  }
  if (values.length !== 1 || !/^Bearer [\x21-\x7E]{32,256}$/.test(values[0]!)) return 401;
  return constantTimeCredentialEqual(values[0]!.slice(7), expected) ? undefined : 401;
}
