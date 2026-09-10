import { randomUUID } from 'node:crypto';
import { execFile as execFileCallback } from 'node:child_process';
import { constants as fsConstants } from 'node:fs';
import { lstat, mkdir, open, rename, stat, unlink } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';

const optionalOpenFlag = (name: 'O_CLOEXEC' | 'O_NOFOLLOW'): number =>
  (fsConstants as unknown as Record<string, number | undefined>)[name] ?? 0;

// Path-component identity must survive ordinary directory mutations such as
// creating the temporary file. Size and timestamps are therefore excluded;
// device/inode/type are the stable replacement check.
type FileIdentity = readonly [number, number, number];
export type FilePathIdentityChain = ReadonlyArray<readonly [string, FileIdentity]>;

function isKnownPosixSystemSymlink(path: string): boolean {
  // macOS exposes /var (and sometimes /tmp) as compatibility symlinks. These
  // are fixed system aliases; configured/user-controlled path components must
  // still be real directories.
  return process.platform !== 'win32' && (path === '/var' || path === '/tmp');
}

function identityOf(value: {
  dev: number;
  ino: number;
  mode: number;
}): FileIdentity {
  return [value.dev, value.ino, value.mode];
}

function sameIdentity(left: FileIdentity, right: FileIdentity): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function canonicalWindowsSid(value: string, allowAliases = true): string | undefined {
  const aliases: Record<string, string> = {
    ...(allowAliases ? {
      SY: 'S-1-5-18',
      BA: 'S-1-5-32-544',
      WD: 'S-1-1-0',
      AU: 'S-1-5-11',
      BU: 'S-1-5-32-545',
      IU: 'S-1-5-4',
      AN: 'S-1-5-7',
      NU: 'S-1-5-2',
      AC: 'S-1-15-2-1',
    } : {}),
  };
  const normalized = value.trim().toUpperCase();
  if (aliases[normalized] !== undefined) return aliases[normalized];
  if (!/^S-1-(?:\d+)(?:-\d+)+$/.test(normalized)) return undefined;
  const parts = normalized.split('-');
  for (let index = 2; index < parts.length; index += 1) {
    if (Number(parts[index]) < 0 || !Number.isSafeInteger(Number(parts[index]))) return undefined;
    parts[index] = String(Number(parts[index]));
  }
  return parts.join('-');
}

function expectedParentIdentity(
  chain: FilePathIdentityChain,
  parent: string,
): FileIdentity {
  const expected = chain.find(([component]) => component === parent)?.[1];
  if (expected === undefined) throw new Error('unsafe_write_directory');
  return expected;
}

/**
 * Authenticate the descriptor selected for the directory before any child
 * entry is created. This is intentionally separate from the later path-chain
 * checks: the descriptor must match the identity captured before open().
 */
export function assertOpenedDirectoryIdentity(
  opened: { dev: number; ino: number; mode: number; isDirectory(): boolean },
  expected: FileIdentity,
): void {
  if (!opened.isDirectory() || !sameIdentity(identityOf(opened), expected)) {
    throw new Error('unsafe_write_directory');
  }
}

/** Capture existing path components without resolving or following a reparse point. */
export async function captureFilePathIdentityChain(path: string): Promise<FilePathIdentityChain> {
  const absolute = resolve(path);
  const leaf = absolute;
  const chain: Array<[string, FileIdentity]> = [];
  let current = absolute;
  while (true) {
    let observed;
    try {
      observed = await lstat(current);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') break;
      throw error;
    }
    if (observed.isSymbolicLink() && (current === leaf || !isKnownPosixSystemSymlink(current))) {
      throw new Error('unsafe_path_component');
    }
    chain.push([current, identityOf(observed)]);
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return chain.reverse();
}

export async function assertFilePathIdentityChain(
  path: string,
  expected: FilePathIdentityChain,
): Promise<void> {
  const actual = await captureFilePathIdentityChain(path);
  if (actual.length !== expected.length) throw new Error('path_changed');
  for (let index = 0; index < expected.length; index += 1) {
    const [expectedPath, expectedIdentity] = expected[index];
    const [actualPath, actualIdentity] = actual[index];
    if (
      expectedPath !== actualPath
      || expectedIdentity.length !== actualIdentity.length
      || expectedIdentity.some((value, identityIndex) => value !== actualIdentity[identityIndex])
    ) {
      throw new Error('path_changed');
    }
  }
}

const execFile = promisify(execFileCallback);
const WINDOWS_ACL_QUERY_TIMEOUT_MS = 5_000;
const WINDOWS_ACL_QUERY_MAX_BYTES = 256 * 1024;
const WINDOWS_BROAD_ACL_TRUSTEES = new Set([
  'WD', 'AU', 'BU', 'IU', 'AN', 'NU', 'AC',
  'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-32-546', 'S-1-5-4', 'S-1-5-7', 'S-1-5-2',
  'S-1-5-19', 'S-1-5-20',
]);
const WINDOWS_CANONICAL_BROAD_ACL_TRUSTEES = new Set(
  [...WINDOWS_BROAD_ACL_TRUSTEES]
    .map(value => canonicalWindowsSid(value))
    .filter((value): value is string => value !== undefined),
);
const WINDOWS_SDDL_WRITE_RIGHTS = new Set([
  'FA', 'FW', 'GA', 'GW', 'CC', 'DC', 'DT', 'WD', 'AD', 'WE', 'WA', 'SD', 'WO', 'WP', 'SW', 'WDAC',
]);
const WINDOWS_SDDL_READ_ONLY_RIGHTS = new Set([
  'FR', 'FX', 'GR', 'GX', 'RC', 'RD', 'RA', 'RE', 'RP', 'LC', 'LO', 'CR',
]);

function sddlRightsGrantWrite(rights: string): boolean {
  const normalized = rights.toUpperCase();
  if (!normalized) return false;
  if (normalized.startsWith('0X')) return true;
  const tokens = normalized.match(/[A-Z]{2}/g) ?? [];
  if (tokens.join('') !== normalized) return true;
  return tokens.some(token => WINDOWS_SDDL_WRITE_RIGHTS.has(token) || !WINDOWS_SDDL_READ_ONLY_RIGHTS.has(token));
}

/** Validate the mutation boundary mirrored by the Windows deployment ACL verifier. */
export function validateWindowsAclSddl(
  sddl: string,
  currentSid: string,
  managementSid?: string,
): void {
  const ownerMatch = /(?:^|:)O:([^G]+)G:/i.exec(sddl);
  const daclMatch = /D:(.*?)(?::S:|$)/i.exec(sddl);
  if (!ownerMatch || !daclMatch) throw new Error('unsafe_storage_contract');
  const owner = canonicalWindowsSid(ownerMatch[1]);
  const current = canonicalWindowsSid(currentSid, false);
  const management = managementSid === undefined
    ? undefined
    : canonicalWindowsSid(managementSid, false);
  if (
    owner === undefined
    || current === undefined
    || (managementSid !== undefined && management === undefined)
    || WINDOWS_CANONICAL_BROAD_ACL_TRUSTEES.has(owner)
  ) throw new Error('unsafe_storage_contract');
  // This is the same management boundary as Assert-RestrictedAcl: SYSTEM,
  // local Administrators, the running service/operator identity, and the
  // installer-recorded management SID. The observed owner is never added.
  const trusted = new Set(['S-1-5-18', 'S-1-5-32-544', current]);
  if (management !== undefined) trusted.add(management);
  if (!trusted.has(owner)) throw new Error('unsafe_storage_contract');
  const aces = [...daclMatch[1].matchAll(/\(([^()]*)\)/g)];
  if (!aces.length) throw new Error('unsafe_storage_contract');
  for (const match of aces) {
    const fields = match[1].split(';');
    if (fields.length !== 6) throw new Error('unsafe_storage_contract');
    const aceType = fields[0].toUpperCase();
    const rawTrustee = fields[5].trim().toUpperCase();
    const trustee = canonicalWindowsSid(rawTrustee);
    if (aceType === 'D' || aceType === 'OD') throw new Error('unsafe_storage_contract');
    if (aceType !== 'A' && aceType !== 'OA') throw new Error('unsafe_storage_contract');
    if (trustee === undefined) throw new Error('unsafe_storage_contract');
    if (
      sddlRightsGrantWrite(fields[2])
      && (!trusted.has(trustee) || WINDOWS_CANONICAL_BROAD_ACL_TRUSTEES.has(trustee))
    ) throw new Error('unsafe_storage_contract');
  }
}

async function readBoundedManagementSid(path: string): Promise<string | undefined> {
  const expected = await captureFilePathIdentityChain(path);
  if (!expected.length) return undefined;
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 64 * 1024) return undefined;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(path, fsConstants.O_RDONLY | optionalOpenFlag('O_NOFOLLOW') | optionalOpenFlag('O_CLOEXEC'));
    const opened = await handle.stat();
    if (!opened.isFile() || !sameIdentity(identityOf(opened), identityOf(metadata))) return undefined;
    const chunks: Buffer[] = [];
    let totalBytes = 0;
    while (totalBytes <= 64 * 1024) {
      const buffer = Buffer.alloc(Math.min(8192, 64 * 1024 + 1 - totalBytes));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      chunks.push(buffer.subarray(0, bytesRead));
      totalBytes += bytesRead;
    }
    if (totalBytes > 64 * 1024) return undefined;
    const body = Buffer.concat(chunks, totalBytes);
    const finished = await handle.stat();
    if (
      !finished.isFile()
      || !sameIdentity(identityOf(finished), identityOf(opened))
      || finished.size !== opened.size
      || finished.mtimeMs !== opened.mtimeMs
      || finished.ctimeMs !== opened.ctimeMs
      || totalBytes !== opened.size
    ) return undefined;
    const actual = await captureFilePathIdentityChain(path);
    if (actual.length !== expected.length) return undefined;
    for (let index = 0; index < expected.length; index += 1) {
      const expectedEntry = expected[index];
      const actualEntry = actual[index];
      if (expectedEntry === undefined || actualEntry === undefined) return undefined;
      const [expectedComponent, expectedIdentity] = expectedEntry;
      const [component, identity] = actualEntry;
      if (component !== expectedComponent || !sameIdentity(identity, expectedIdentity)) return undefined;
    }
    const decoded: unknown = JSON.parse(body.toString('utf8'));
    if (typeof decoded !== 'object' || decoded === null || Array.isArray(decoded)) return undefined;
    const candidate = (decoded as { managementSid?: unknown }).managementSid;
    if (typeof candidate !== 'string' || candidate !== candidate.trim()) return undefined;
    return canonicalWindowsSid(candidate, false);
  } catch {
    return undefined;
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

async function configuredManagementSid(): Promise<string | undefined> {
  const secretFile = process.env.LIFEOS_LOCAL_API_SECRET_FILE;
  const usageStore = process.env.USAGE_STORE_PATH;
  if (process.platform !== 'win32' || !secretFile || !usageStore || process.env.PORT !== '8787') return undefined;
  const secretRoot = resolve(dirname(secretFile));
  const dataRoot = resolve(dirname(dirname(usageStore)));
  const deploymentRoot = dirname(secretRoot);
  if (
    basename(secretRoot).toLowerCase() !== 'lifeos-secrets'
    || basename(dataRoot).toLowerCase() !== 'lifeos-data'
    || dirname(dataRoot) !== deploymentRoot
  ) return undefined;
  return readBoundedManagementSid(join(deploymentRoot, 'lifeos-services', 'host', 'config', 'LifeOSAPI.json'));
}

async function windowsAclSddlBatch(paths: readonly string[]): Promise<readonly [string, string][]> {
  const systemRoot = process.env.SystemRoot ?? process.env.SYSTEMROOT;
  if (!systemRoot) throw new Error('unsafe_storage_contract');
  const powershell = join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const script = [
    "$ErrorActionPreference = 'Stop'",
    "$paths = ConvertFrom-Json -InputObject $env:LIFEOS_ACL_QUERY_PATHS",
    "$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value",
    "$entries = @($paths | ForEach-Object { $path = [string]$_; $acl = Get-Acl -LiteralPath $path -ErrorAction Stop; [pscustomobject]@{ path = $path; sddl = [string]$acl.Sddl } })",
    "[Console]::Out.WriteLine(([pscustomobject]@{ sid = $currentSid; entries = $entries } | ConvertTo-Json -Compress -Depth 4))",
  ].join('; ');
  const encoded = Buffer.from(script, 'utf16le').toString('base64');
  const serializedPaths = JSON.stringify(paths);
  if (serializedPaths.length > 64 * 1024) throw new Error('unsafe_storage_contract');
  try {
    const result = await execFile(
      powershell,
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
      {
        env: {
          SystemRoot: systemRoot,
          SYSTEMROOT: systemRoot,
          LIFEOS_ACL_QUERY_PATHS: serializedPaths,
        },
        maxBuffer: WINDOWS_ACL_QUERY_MAX_BYTES,
        timeout: WINDOWS_ACL_QUERY_TIMEOUT_MS,
        killSignal: 'SIGTERM',
        windowsHide: true,
      },
    );
    const decoded: unknown = JSON.parse(String(result.stdout).trim());
    if (typeof decoded !== 'object' || decoded === null || Array.isArray(decoded)) throw new Error('unsafe_storage_contract');
    const value = decoded as { sid?: unknown; entries?: unknown };
    if (typeof value.sid !== 'string' || !Array.isArray(value.entries) || value.entries.length !== paths.length) {
      throw new Error('unsafe_storage_contract');
    }
    return value.entries.map((entry, index) => {
      if (
        typeof entry !== 'object'
        || entry === null
        || Array.isArray(entry)
        || (entry as { path?: unknown }).path !== paths[index]
        || typeof (entry as { sddl?: unknown }).sddl !== 'string'
      ) throw new Error('unsafe_storage_contract');
      return [(entry as { sddl: string }).sddl, value.sid as string] as const;
    });
  } catch {
    throw new Error('unsafe_storage_contract');
  }
}

/**
 * Check the complete existing storage boundary used when Node has no
 * handle-relative file operation. On POSIX this is a mode/owner contract for
 * the fallback runtime; on Windows it mirrors Assert-RestrictedAcl and
 * Assert-NoBroadAcl from the deployment verifier for mutation-relevant ACEs.
 */
export async function assertStoragePathContract(
  path: string,
  expectedChain?: FilePathIdentityChain,
): Promise<void> {
  const parent = resolve(path);
  const actual = await captureFilePathIdentityChain(parent);
  if (
    expectedChain !== undefined
    && (
      actual.length !== expectedChain.length
      || actual.some(([actualPath, actualIdentity], index) => {
        const [expectedPath, expectedIdentity] = expectedChain[index];
        return actualPath !== expectedPath || !sameIdentity(actualIdentity, expectedIdentity);
      })
    )
  ) throw new Error('path_changed');
  if (!actual.length || actual[actual.length - 1][0] !== parent) {
    throw new Error('unsafe_storage_contract');
  }

  if (process.platform === 'win32') {
    const managementSid = await configuredManagementSid();
    const aclResults = await windowsAclSddlBatch(actual.map(([component]) => component));
    for (const [sddl, currentSid] of aclResults) {
      validateWindowsAclSddl(sddl, currentSid, managementSid);
    }
    return;
  }

  // Node core has no openat/renameat API on macOS. The fallback is safe only
  // when every existing component is owned/protected by this account; sticky
  // system temp aliases are the one intentional shared-directory exception.
  if (typeof process.getuid !== 'function') throw new Error('unsafe_storage_contract');
  const uid = process.getuid();
  for (const [component] of actual) {
    const observed = await lstat(component);
    if (observed.isSymbolicLink() && isKnownPosixSystemSymlink(component)) continue;
    if (!observed.isDirectory()) throw new Error('unsafe_storage_contract');
    const mode = observed.mode & 0o7777;
    const stickySharedDirectory = (mode & 0o1000) !== 0
      && (
        component === '/tmp'
        || component === '/var'
        || component === '/var/tmp'
        || component === '/private/tmp'
        || component === '/private/var/tmp'
      );
    if ((mode & 0o022) !== 0 && !stickySharedDirectory) throw new Error('unsafe_storage_contract');
    if (component === parent && observed.uid !== uid && !stickySharedDirectory) {
      throw new Error('unsafe_storage_contract');
    }
    if (observed.uid !== uid && observed.uid !== 0 && (mode & 0o200) !== 0) {
      throw new Error('unsafe_storage_contract');
    }
  }
}

async function descriptorRelativePath(
  directory: Awaited<ReturnType<typeof open>>,
  name: string,
): Promise<string | undefined> {
  if (process.platform === 'win32') return undefined;
  for (const root of ['/proc/self/fd', '/dev/fd']) {
    try {
      // Keep the trailing component: stat(root/fd) follows the fd symlink,
      // while stat(root/fd/.) tests whether nested traversal is available.
      const observed = await stat(`${root}/${directory.fd}/.`);
      if (observed.isDirectory()) return join(root, String(directory.fd), name);
    } catch {
      // Try the next platform-provided descriptor namespace.
    }
  }
  return undefined;
}

/**
 * Publish a bounded file as a durable commit point.
 *
 * The destination is never opened for writing. A uniquely named file is
 * written, flushed, and synced before the atomic rename. A directory sync is
 * attempted on POSIX so the rename itself survives a power loss where the
 * filesystem supports directory fsync; Windows does not expose that contract
 * through Node and relies on the atomic rename/ReplaceFile implementation.
 */
export async function atomicWriteFile(path: string, data: string | Buffer, mode = 0o600): Promise<void> {
  const target = resolve(path);
  const parent = dirname(target);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const parentChain = await captureFilePathIdentityChain(parent);
  const targetChain = await captureFilePathIdentityChain(target);
  const existing = await lstat(target).catch(error => {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw error;
  });
  if (existing !== undefined && !existing.isFile()) throw new Error('unsafe_write_target');

  const temporaryName = `.${basename(target)}.tmp-${process.pid}-${randomUUID()}`;
  const temporary = join(parent, temporaryName);
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  let directory: Awaited<ReturnType<typeof open>> | undefined;
  let relativeTemporary: string | undefined;
  let relativeTarget: string | undefined;
  let absolutePathBound = false;
  try {
    await assertFilePathIdentityChain(parent, parentChain);
    await assertFilePathIdentityChain(target, targetChain);
    if (process.platform !== 'win32') {
      if (fsConstants.O_DIRECTORY === undefined) {
        throw new Error('descriptor_relative_write_unavailable');
      }
      const fixedSystemAlias = isKnownPosixSystemSymlink(parent);
      // Capture the expected identity before open(). For ordinary paths this
      // is the already-captured final chain component. For /var and /tmp,
      // capture the fixed alias target before intentionally following it.
      const expectedDirectoryIdentity = fixedSystemAlias
        ? identityOf(await stat(parent))
        : expectedParentIdentity(parentChain, parent);
      directory = await open(
        parent,
        fsConstants.O_RDONLY
          | fsConstants.O_DIRECTORY
          | (fixedSystemAlias ? 0 : optionalOpenFlag('O_NOFOLLOW'))
          | optionalOpenFlag('O_CLOEXEC'),
      );
      const opened = await directory.stat();
      assertOpenedDirectoryIdentity(opened, expectedDirectoryIdentity);
    }
    if (directory !== undefined) {
      relativeTemporary = await descriptorRelativePath(directory, temporaryName);
      if (relativeTemporary !== undefined) {
        relativeTarget = await descriptorRelativePath(directory, basename(target));
        if (relativeTarget === undefined) relativeTemporary = undefined;
      }
    }
    if (relativeTemporary === undefined) {
      // Node core has no openat/renameat boundary on macOS and Windows. The
      // absolute path fallback is allowed only under the complete protected
      // ancestor contract; post-write identity checks are detection only.
      await assertStoragePathContract(parent, parentChain);
      absolutePathBound = true;
    }
    const temporaryFlags = fsConstants.O_WRONLY
      | fsConstants.O_CREAT
      | fsConstants.O_EXCL
      | optionalOpenFlag('O_NOFOLLOW')
      | optionalOpenFlag('O_CLOEXEC');
    handle = await open(
      relativeTemporary ?? temporary,
      temporaryFlags,
      mode,
    );
    await handle.writeFile(data);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await assertFilePathIdentityChain(parent, parentChain);
    await assertFilePathIdentityChain(target, targetChain);
    let committed;
    if (relativeTemporary !== undefined && relativeTarget !== undefined) {
      await rename(relativeTemporary, relativeTarget);
      committed = await lstat(relativeTarget);
    } else {
      await assertStoragePathContract(parent, parentChain);
      await rename(temporary, target);
      committed = await lstat(target);
    }
    if (!committed.isFile() || committed.isSymbolicLink()) throw new Error('unsafe_write_target');
    await assertFilePathIdentityChain(parent, parentChain);
    if (directory !== undefined) {
      try {
        await directory.sync();
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code !== 'EINVAL' && code !== 'ENOTSUP' && code !== 'EISDIR') throw error;
      }
    }
  } finally {
    await handle?.close().catch(() => undefined);
    if (relativeTemporary !== undefined) {
      await unlink(relativeTemporary).catch(() => undefined);
    } else if (absolutePathBound) {
      // Recheck before path-based cleanup. If the boundary changed, leaving a
      // temp entry in the old protected directory is safer than unlinking a
      // substituted path.
      try {
        await assertStoragePathContract(parent, parentChain);
        await unlink(temporary);
      } catch {
        // Cleanup is best effort after a failed boundary check.
      }
    }
    await directory?.close().catch(() => undefined);
  }
}
