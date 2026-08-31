import { randomUUID } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { mkdir, open, rename, unlink } from 'node:fs/promises';
import { dirname } from 'node:path';

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
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(temporary, fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL, mode);
    await handle.writeFile(data);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporary, path);
    await syncDirectory(dirname(path));
  } finally {
    await handle?.close().catch(() => undefined);
    await unlink(temporary).catch(() => undefined);
  }
}

async function syncDirectory(path: string): Promise<void> {
  if (process.platform === 'win32' || fsConstants.O_DIRECTORY === undefined) return;
  let directory: Awaited<ReturnType<typeof open>> | undefined;
  try {
    directory = await open(path, fsConstants.O_RDONLY | fsConstants.O_DIRECTORY);
    await directory.sync();
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== 'EINVAL' && code !== 'ENOTSUP' && code !== 'EISDIR') throw error;
  } finally {
    await directory?.close().catch(() => undefined);
  }
}
