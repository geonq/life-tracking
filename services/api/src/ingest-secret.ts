import { constants as fsConstants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';

/** Keep file-backed bearer credentials bounded and reject accidental text files. */
export const INGEST_SECRET_MAX_FILE_BYTES = 4 * 1024;
export const INGEST_SECRET_MIN_LENGTH = 32;
export const INGEST_SECRET_MAX_LENGTH = 256;
const INGEST_SECRET_OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);

const isRestrictiveMode = (mode: number) => process.platform === 'win32' || (mode & 0o077) === 0;

export function validateIngestSecret(value: string | undefined): string | undefined {
  if (!value || value.length < INGEST_SECRET_MIN_LENGTH || value.length > INGEST_SECRET_MAX_LENGTH) return undefined;
  if (Buffer.byteLength(value, 'utf8') > INGEST_SECRET_MAX_FILE_BYTES || !/^[\x21-\x7E]+$/.test(value)) return undefined;
  return value;
}

/**
 * Read one secret without following a symlink and without trusting a path that
 * changes between the metadata and the open/read operations.
 */
export async function readIngestSecretFile(pathValue: string | undefined): Promise<string | undefined> {
  if (!pathValue || pathValue.includes('\0') || !isAbsolute(pathValue)) return undefined;
  let file: Awaited<ReturnType<typeof open>> | undefined;
  try {
    const path = resolve(pathValue);
    const metadata = await lstat(path);
    if (!metadata.isFile() || metadata.isSymbolicLink()
      || metadata.size > INGEST_SECRET_MAX_FILE_BYTES || !isRestrictiveMode(metadata.mode)) return undefined;
    file = await open(path, INGEST_SECRET_OPEN_FLAGS);
    const opened = await file.stat();
    if (!opened.isFile() || opened.isSymbolicLink() || !isRestrictiveMode(opened.mode)
      || opened.dev !== metadata.dev || opened.ino !== metadata.ino || opened.size !== metadata.size) return undefined;
    const buffer = Buffer.alloc(INGEST_SECRET_MAX_FILE_BYTES + 1);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    if (bytesRead > INGEST_SECRET_MAX_FILE_BYTES || bytesRead !== opened.size) return undefined;
    return validateIngestSecret(buffer.subarray(0, bytesRead).toString('utf8'));
  } catch {
    return undefined;
  } finally {
    if (file) await file.close().catch(() => undefined);
  }
}
