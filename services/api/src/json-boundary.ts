import { TextDecoder } from 'node:util';

/**
 * Parse JSON at a transport boundary without accepting ambiguous duplicate
 * object members. JSON.parse otherwise keeps the last value, which lets two
 * producers assign different meanings to the same bytes.
 */
export function parseStrictJSON(input: string | Buffer): unknown {
  let source: string;
  let parsed: unknown;
  try {
    source = Buffer.isBuffer(input)
      ? new TextDecoder('utf-8', { fatal: true }).decode(input)
      : input;
    parsed = JSON.parse(source);
    if (hasDuplicateObjectKeys(source)) throw new Error('duplicate_json_key');
  } catch {
    throw new Error('invalid_json');
  }
  return parsed;
}

function hasDuplicateObjectKeys(source: string): boolean {
  let cursor = 0;
  const skipWhitespace = () => {
    while (cursor < source.length && /\s/.test(source[cursor]!)) cursor += 1;
  };
  const skipString = () => {
    cursor += 1;
    while (cursor < source.length) {
      if (source[cursor] === '\\') {
        cursor += 2;
        continue;
      }
      if (source[cursor] === '"') {
        cursor += 1;
        return;
      }
      cursor += 1;
    }
  };
  const skipPrimitive = () => {
    while (cursor < source.length && !/[\s,\]}]/.test(source[cursor]!)) cursor += 1;
  };
  const parseValue = (): boolean => {
    skipWhitespace();
    const character = source[cursor];
    if (character === '"') {
      skipString();
      return false;
    }
    if (character === '[') {
      cursor += 1;
      skipWhitespace();
      while (source[cursor] !== ']') {
        if (parseValue()) return true;
        skipWhitespace();
        if (source[cursor] === ',') cursor += 1;
        skipWhitespace();
      }
      cursor += 1;
      return false;
    }
    if (character === '{') {
      cursor += 1;
      const keys = new Set<string>();
      skipWhitespace();
      while (source[cursor] !== '}') {
        if (source[cursor] !== '"') return false;
        const keyStart = cursor;
        skipString();
        const key = JSON.parse(source.slice(keyStart, cursor)) as string;
        if (keys.has(key)) return true;
        keys.add(key);
        skipWhitespace();
        if (source[cursor] !== ':') return false;
        cursor += 1;
        if (parseValue()) return true;
        skipWhitespace();
        if (source[cursor] === ',') cursor += 1;
        skipWhitespace();
      }
      cursor += 1;
      return false;
    }
    skipPrimitive();
    return false;
  };
  return parseValue();
}
