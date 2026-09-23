import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  appendFileSync,
  closeSync,
  mkdirSync,
  mkdtempSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  truncateSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { GoogleFoodPhotoProposalClient, NutritionPhotoProposalError, createConfiguredNutritionPhotoProposalClient } from './nutrition-photo.js';

const fsControl = vi.hoisted(() => ({
  hooks: {} as Record<string, (...args: any[]) => any>,
  calls: {} as Record<string, number>,
}));

vi.mock('node:fs', async importOriginal => {
  const actual = await importOriginal<typeof import('node:fs')>();
  const wrap = (name: string, operation: (...args: any[]) => any) => (...args: any[]) => {
    fsControl.calls[name] = (fsControl.calls[name] ?? 0) + 1;
    const hook = fsControl.hooks[name];
    return hook ? hook(operation, ...args) : operation(...args);
  };
  return {
    ...actual,
    lstatSync: wrap('lstatSync', actual.lstatSync),
    openSync: wrap('openSync', actual.openSync),
    fstatSync: wrap('fstatSync', actual.fstatSync),
    readSync: wrap('readSync', actual.readSync),
    closeSync: wrap('closeSync', actual.closeSync),
  };
});

const temporaryDirectories: string[] = [];

function makeTemporaryDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), 'lifeos-google-key-'));
  temporaryDirectories.push(directory);
  return directory;
}

function successfulResponse(): Response {
  return new Response(JSON.stringify({
    candidates: [{ content: { parts: [{ text: JSON.stringify(providerBody) }] } }],
  }), { status: 200, headers: { 'content-type': 'application/json' } });
}

function configuredFileClient(
  keyPath: string,
  fetch: (input: string | URL, init?: RequestInit) => Promise<Response> = async () => successfulResponse(),
) {
  return createConfiguredNutritionPhotoProposalClient({
    GOOGLE_AI_STUDIO_ENABLED: 'true',
    GOOGLE_AI_STUDIO_API_KEY_FILE: keyPath,
    GOOGLE_AI_STUDIO_FOOD_MODEL: 'gemini-test',
  }, { fetch });
}

async function expectKeyUsed(keyPath: string, expectedKey: string): Promise<void> {
  const fetch = vi.fn(async (_input: string | URL, _init?: RequestInit) => successfulResponse());
  await expect(configuredFileClient(keyPath, fetch).generate(manifest)).resolves.toMatchObject({ state: 'needs_confirmation' });
  expect(fetch).toHaveBeenCalledTimes(1);
  const init = fetch.mock.calls[0]?.[1];
  expect((init?.headers as Record<string, string>)['x-goog-api-key']).toBe(expectedKey);
}

async function expectUnavailable(keyPath: string, fetch = vi.fn(async () => successfulResponse())): Promise<void> {
  await expect(configuredFileClient(keyPath, fetch).generate(manifest))
    .rejects.toMatchObject({ code: 'configuration_unavailable' });
  expect(fetch).not.toHaveBeenCalled();
}

beforeEach(() => {
  fsControl.hooks = {};
  fsControl.calls = {};
});

afterEach(() => {
  vi.restoreAllMocks();
  fsControl.hooks = {};
  fsControl.calls = {};
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

const manifest = {
  schemaVersion: 1,
  mealID: 'meal-photo-1',
  requestID: 'request-photo-1',
  capturedAt: new Date().toISOString(),
  clientTimeZone: 'Europe/Berlin',
  inferenceConsent: true,
  images: [{
    imageID: 'image-1',
    mimeType: 'image/jpeg',
    byteLength: 1,
    width: 100,
    height: 100,
    sanitized: true,
    inlineDataBase64: 'AA==',
    sha256: 'a'.repeat(64),
  }],
} as const;

const providerBody = {
  items: [{
    itemID: 'item-1',
    estimatedLabel: 'Plain yogurt',
    labelSource: 'recognized',
    quantity: 1,
    unit: 'portion',
    grams: { estimate: 100, min: 90, max: 110 },
    calories: { estimate: 100, min: 90, max: 110 },
    protein: { estimate: 5, min: 4, max: 6 },
    carbs: { estimate: 10, min: 8, max: 12 },
    fat: { estimate: 2, min: 1, max: 3 },
    confidence: 'medium',
    flags: ['needs_confirmation'],
  }],
  totals: {
    grams: { estimate: 100, min: 90, max: 110 },
    calories: { estimate: 100, min: 90, max: 110 },
    protein: { estimate: 5, min: 4, max: 6 },
    carbs: { estimate: 10, min: 8, max: 12 },
    fat: { estimate: 2, min: 1, max: 3 },
  },
  flags: ['needs_confirmation'],
};

describe('configured Google key descriptor boundary', () => {
  it('accepts a regular key with surrounding whitespace after trimming', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, '  trimmed-google-key\n');

    await expectKeyUsed(keyPath, 'trimmed-google-key');
    expect(fsControl.calls.openSync).toBe(1);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('accepts exactly 4,096 valid ASCII bytes', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    const secret = 'k'.repeat(4_096);
    writeFileSync(keyPath, secret);

    await expectKeyUsed(keyPath, secret);
    expect(fsControl.calls.openSync).toBe(1);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('rejects 4,097 bytes before opening the file', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'k'.repeat(4_097));

    await expectUnavailable(keyPath);
    expect(fsControl.calls.openSync ?? 0).toBe(0);
    expect(fsControl.calls.readSync ?? 0).toBe(0);
  });

  it.each([
    ['empty', ''],
    ['whitespace only', ' \n\t '],
    ['internal spaces', 'key with spaces'],
    ['internal newline', 'first\nsecond'],
    ['NUL', 'bad\0key'],
    ['DEL', 'bad\u007fkey'],
  ])('rejects %s key content without contacting the provider', async (_label, content) => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, content);

    await expectUnavailable(keyPath);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('rejects NUL and overlong paths before filesystem access', async () => {
    const nulPath = `${join(makeTemporaryDirectory(), 'google.key')}\0ignored`;
    await expectUnavailable(nulPath);
    expect(fsControl.calls.lstatSync ?? 0).toBe(0);
    expect(fsControl.calls.openSync ?? 0).toBe(0);

    fsControl.calls = {};
    await expectUnavailable('x'.repeat(4_097));
    expect(fsControl.calls.lstatSync ?? 0).toBe(0);
    expect(fsControl.calls.openSync ?? 0).toBe(0);
  });

  it('rejects symlink paths before opening them', async context => {
    const directory = makeTemporaryDirectory();
    const targetPath = join(directory, 'target.key');
    const linkPath = join(directory, 'linked.key');
    writeFileSync(targetPath, 'valid-google-key');
    try {
      symlinkSync(targetPath, linkPath);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (process.platform === 'win32' && (code === 'EPERM' || code === 'EACCES')) context.skip();
      throw error;
    }

    await expectUnavailable(linkPath);
    expect(fsControl.calls.openSync ?? 0).toBe(0);
  });

  it('rejects directory paths before opening them', async () => {
    const directory = makeTemporaryDirectory();
    const directoryPath = join(directory, 'nested');
    mkdirSync(directoryPath);
    writeFileSync(join(directoryPath, 'placeholder'), 'x');

    await expectUnavailable(directoryPath);
    expect(fsControl.calls.openSync ?? 0).toBe(0);
  });

  it('rejects a deterministic same-size pathname substitution before reading', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    const replacementPath = join(directory, 'replacement.key');
    const parkedPath = join(directory, 'original.key');
    writeFileSync(keyPath, 'old-key');
    writeFileSync(replacementPath, 'new-key');
    fsControl.hooks.lstatSync = (operation, pathValue, ...args) => {
      const metadata = operation(pathValue, ...args);
      if (pathValue === keyPath) {
        renameSync(keyPath, parkedPath);
        renameSync(replacementPath, keyPath);
      }
      return metadata;
    };

    await expectUnavailable(keyPath);
    expect(fsControl.calls.readSync ?? 0).toBe(0);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('rejects a POSIX symlink swap at the single open', async context => {
    if (process.platform === 'win32') context.skip();
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    const replacementPath = join(directory, 'replacement.key');
    writeFileSync(keyPath, 'original-key');
    writeFileSync(replacementPath, 'replacement-key');
    fsControl.hooks.lstatSync = (operation, pathValue, ...args) => {
      const metadata = operation(pathValue, ...args);
      if (pathValue === keyPath) {
        unlinkSync(keyPath);
        symlinkSync(replacementPath, keyPath);
      }
      return metadata;
    };

    await expectUnavailable(keyPath);
    expect(fsControl.calls.readSync ?? 0).toBe(0);
    expect(fsControl.calls.closeSync ?? 0).toBe(0);
  });

  it('reads the already-open original when the pathname is redirected afterward', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    const replacementPath = join(directory, 'replacement.key');
    const parkedPath = join(directory, 'original.key');
    writeFileSync(keyPath, 'original-google-key');
    writeFileSync(replacementPath, 'replacement-google-key');
    fsControl.hooks.openSync = (operation, pathValue, ...args) => {
      const descriptor = operation(pathValue, ...args);
      if (pathValue === keyPath) {
        try {
          renameSync(keyPath, parkedPath);
          renameSync(replacementPath, keyPath);
        } catch (error) {
          try {
            closeSync(descriptor);
          } catch {
            // Preserve the pathname-redirection failure.
          }
          throw error;
        }
      }
      return descriptor;
    };

    await expectKeyUsed(keyPath, 'original-google-key');
    expect(fsControl.calls.openSync).toBe(1);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('handles short descriptor reads without losing bytes', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'short-read-key');
    fsControl.hooks.readSync = (operation, descriptor, buffer, offset, length, position) =>
      operation(descriptor, buffer, offset, Math.min(length, 2), position);

    await expectKeyUsed(keyPath, 'short-read-key');
    expect(fsControl.calls.readSync).toBeGreaterThan(1);
  });

  it('rejects growth after the initial descriptor stat', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'k'.repeat(4_096));
    fsControl.hooks.fstatSync = (operation, descriptor, ...args) => {
      const metadata = operation(descriptor, ...args);
      if (fsControl.calls.fstatSync === 1) appendFileSync(keyPath, 'x'.repeat(12_288));
      return metadata;
    };
    let cumulativeBytesRead = 0;
    fsControl.hooks.readSync = (operation, descriptor, buffer, offset, length, position) => {
      const bytesRead = operation(descriptor, buffer, offset, length, position);
      cumulativeBytesRead += bytesRead;
      expect(cumulativeBytesRead).toBeLessThanOrEqual(4_097);
      return bytesRead;
    };

    await expectUnavailable(keyPath);
    expect(fsControl.calls.readSync).toBeGreaterThan(0);
    expect(cumulativeBytesRead).toBe(4_097);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('rejects truncation after the initial descriptor stat', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'k'.repeat(256));
    fsControl.hooks.fstatSync = (operation, descriptor, ...args) => {
      const metadata = operation(descriptor, ...args);
      if (fsControl.calls.fstatSync === 1) truncateSync(keyPath, 100);
      return metadata;
    };

    await expectUnavailable(keyPath);
    expect(fsControl.calls.fstatSync).toBe(1);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('rejects same-size metadata mutation observed by the final stat', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'stable-key');
    fsControl.hooks.fstatSync = (operation, descriptor, ...args) => {
      const metadata = operation(descriptor, ...args);
      if (fsControl.calls.fstatSync !== 2) return metadata;
      return Object.assign(Object.create(Object.getPrototypeOf(metadata)), metadata, {
        mtimeNs: metadata.mtimeNs + 1n,
      });
    };

    await expectUnavailable(keyPath);
    expect(fsControl.calls.fstatSync).toBe(2);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it.each([
    ['lstat', 0],
    ['open', 0],
    ['initial fstat', 1],
    ['final fstat', 1],
    ['read', 1],
  ])('fails closed and closes once after an injected %s error', async (stage, expectedCloseCount) => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'valid-google-key');
    const sentinel = `sensitive-path:${keyPath}:sensitive-secret`;
    const log = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    if (stage === 'lstat') fsControl.hooks.lstatSync = () => { throw new Error(sentinel); };
    if (stage === 'open') fsControl.hooks.openSync = () => { throw new Error(sentinel); };
    if (stage === 'initial fstat' || stage === 'final fstat') {
      fsControl.hooks.fstatSync = (operation, ...args) => {
        if ((stage === 'initial fstat' && fsControl.calls.fstatSync === 1)
          || (stage === 'final fstat' && fsControl.calls.fstatSync === 2)) throw new Error(sentinel);
        return operation(...args);
      };
    }
    if (stage === 'read') fsControl.hooks.readSync = () => { throw new Error(sentinel); };

    const fetch = vi.fn(async () => successfulResponse());
    const error = await configuredFileClient(keyPath, fetch).generate(manifest).catch(error => error);
    expect(error).toMatchObject({
      code: 'configuration_unavailable',
      message: 'configuration_unavailable',
    });
    expect(error).not.toHaveProperty('cause');
    const exposedProperties = Object.getOwnPropertyNames(error as object)
      .map(property => (error as unknown as Record<string, unknown>)[property]);
    expect(JSON.stringify(exposedProperties)).not.toContain(sentinel);
    expect(fetch).not.toHaveBeenCalled();
    expect(fsControl.calls.closeSync ?? 0).toBe(expectedCloseCount);
    expect(log).not.toHaveBeenCalled();
    expect(warn).not.toHaveBeenCalled();
  });

  it('treats a close failure as unavailable without retrying or exposing the error', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'valid-google-key');
    const sentinel = `sensitive-path:${keyPath}:sensitive-secret`;
    const log = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    fsControl.hooks.closeSync = (operation, descriptor) => {
      operation(descriptor);
      throw new Error(sentinel);
    };

    const fetch = vi.fn(async () => successfulResponse());
    await expect(configuredFileClient(keyPath, fetch).generate(manifest))
      .rejects.toMatchObject({ code: 'configuration_unavailable' });
    expect(fsControl.calls.closeSync).toBe(1);
    expect(fetch).not.toHaveBeenCalled();
    expect(log).not.toHaveBeenCalled();
  });

  it('closes descriptor zero exactly once', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    const secret = 'fd-zero-key';
    writeFileSync(keyPath, secret);
    const metadata = statSync(keyPath, { bigint: true });
    const secretBytes = Buffer.from(secret);
    fsControl.hooks.openSync = () => 0;
    fsControl.hooks.fstatSync = () => metadata;
    fsControl.hooks.readSync = (_operation, descriptor, buffer, offset, length, position) => {
      expect(descriptor).toBe(0);
      const start = Number(position);
      const count = Math.min(length, secretBytes.length - start);
      if (count > 0) secretBytes.copy(buffer, offset, start, start + count);
      return count;
    };
    fsControl.hooks.closeSync = (_operation, descriptor) => {
      expect(descriptor).toBe(0);
    };

    await expectKeyUsed(keyPath, secret);
    expect(fsControl.calls.closeSync).toBe(1);
  });

  it('does no file I/O when disabled and ignores raw environment keys', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'file-google-key');
    const disabledFetch = vi.fn(async () => successfulResponse());
    await expect(createConfiguredNutritionPhotoProposalClient({
      GOOGLE_AI_STUDIO_ENABLED: 'false',
      GOOGLE_AI_STUDIO_API_KEY_FILE: keyPath,
      GOOGLE_AI_STUDIO_API_KEY: 'raw-google-key',
    }, { fetch: disabledFetch }).generate(manifest))
      .rejects.toMatchObject({ code: 'configuration_unavailable' });
    expect(fsControl.calls.lstatSync ?? 0).toBe(0);
    expect(fsControl.calls.openSync ?? 0).toBe(0);
    expect(disabledFetch).not.toHaveBeenCalled();

    const rawOnlyFetch = vi.fn(async () => successfulResponse());
    await expect(createConfiguredNutritionPhotoProposalClient({
      GOOGLE_AI_STUDIO_ENABLED: 'true',
      GOOGLE_AI_STUDIO_API_KEY: 'raw-google-key',
    }, { fetch: rawOnlyFetch }).generate(manifest))
      .rejects.toMatchObject({ code: 'configuration_unavailable' });
    expect(fsControl.calls.lstatSync ?? 0).toBe(0);
    expect(rawOnlyFetch).not.toHaveBeenCalled();
  });
});

describe('Google food-photo proposal adapter', () => {
  it('fails closed without the explicit feature flag and key', async () => {
    const client = createConfiguredNutritionPhotoProposalClient({});
    await expect(client.generate(manifest)).rejects.toMatchObject({ code: 'configuration_unavailable' });
  });

  it('loads an enabled Google key from a regular protected file and ignores raw env keys', async () => {
    const directory = makeTemporaryDirectory();
    const keyPath = join(directory, 'google.key');
    writeFileSync(keyPath, 'file-google-key\n', { mode: 0o600 });
    const fileClient = createConfiguredNutritionPhotoProposalClient({
      GOOGLE_AI_STUDIO_ENABLED: 'true',
      GOOGLE_AI_STUDIO_API_KEY_FILE: keyPath,
      GOOGLE_AI_STUDIO_FOOD_MODEL: 'gemini-test',
    }, {
      fetch: async (_input, init) => {
        expect((init?.headers as Record<string, string>)['x-goog-api-key']).toBe('file-google-key');
        return new Response(JSON.stringify({
          candidates: [{ content: { parts: [{ text: JSON.stringify(providerBody) }] } }],
        }), { status: 200 });
      },
    });
    await expect(fileClient.generate(manifest)).resolves.toMatchObject({ state: 'needs_confirmation' });

    const rawOnlyClient = createConfiguredNutritionPhotoProposalClient({
      GOOGLE_AI_STUDIO_ENABLED: 'true',
      GOOGLE_AI_STUDIO_API_KEY: 'raw-google-key',
      GOOGLE_AI_STUDIO_FOOD_MODEL: 'gemini-test',
    });
    await expect(rawOnlyClient.generate(manifest)).rejects.toMatchObject({ code: 'configuration_unavailable' });
  });

  it('keeps the provider key in a header, canonicalizes lineage, and validates the returned proposal', async () => {
    let receivedURL = '';
    let receivedKey = '';
    const client = new GoogleFoodPhotoProposalClient({
      apiKey: 'test-google-key',
      model: 'gemini-test',
      now: () => Date.parse(manifest.capturedAt) + 1_000,
      fetch: async (input, init) => {
        receivedURL = String(input);
        receivedKey = String((init?.headers as Record<string, string>)['x-goog-api-key']);
        const request = JSON.parse(String(init?.body));
        expect(request.contents[0].parts[1].inline_data.data).toBe('AA==');
        expect(request.generationConfig.temperature).toBe(0.1);
        expect(request.generationConfig.responseSchema.properties.items.type).toBe('ARRAY');
        expect(request.generationConfig.responseSchema.properties.totals.required).toContain('calories');
        return new Response(JSON.stringify({
          candidates: [{ content: { parts: [{ text: JSON.stringify(providerBody) }] } }],
        }), { status: 200, headers: { 'content-type': 'application/json' } });
      },
    });

    const proposal = await client.generate(manifest);
    expect(receivedURL).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent');
    expect(receivedURL).not.toContain('test-google-key');
    expect(receivedKey).toBe('test-google-key');
    expect(proposal.mealID).toBe(manifest.mealID);
    expect(proposal.requestID).toBe(manifest.requestID);
    expect(proposal.provenance.provider).toBe('google-ai-studio');
    expect(proposal.provenance.sanitizedImageHashes).toEqual([{ imageID: 'image-1', sha256: 'a'.repeat(64) }]);
    expect(proposal.state).toBe('needs_confirmation');
  });

  it('rejects a provider response that does not match the strict food body', async () => {
    const client = new GoogleFoodPhotoProposalClient({
      apiKey: 'test-google-key',
      model: 'gemini-test',
      fetch: async () => new Response(JSON.stringify({
        candidates: [{ content: { parts: [{ text: JSON.stringify({ ...providerBody, extra: true }) }] } }],
      }), { status: 200 }),
    });
    await expect(client.generate(manifest)).rejects.toBeInstanceOf(NutritionPhotoProposalError);
  });
});
