import { parseTvboxConfig, TvboxConfig } from '../model/TvboxModels';
import { b64decode, utf8Decode, stripNonB64 } from '../util/Coding';

/**
 * 订阅内容解码失败异常（四层解码链全部失败时抛出）
 */
export class ConfigDecodeError extends Error {
  constructor(msg: string) { super(msg); }
}

// JSON5 宽松解析（真实订阅源形态，单遍全文扫描——字符串状态跨行延续）：
// 字符串外剥 // 注释（到行尾）、字符串内保留转义对；随后剥全部控制字符
// （修字符串内原始换行如 "优\n酷"、脏 \t/\r 等）→ JSON.parse
function parseJson5ish(text: string): Record<string, Object> {
  let out = '';
  let inStr = false;
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text.charAt(i);
    if (inStr) {
      if (c === '\\' && i + 1 < n) { out += c; out += text.charAt(i + 1); i += 2; continue; }
      if (c === '"') { inStr = false; }
      out += c; i++; continue;
    }
    if (c === '/' && i + 1 < n && text.charAt(i + 1) === '/') {
      while (i < n && text.charAt(i) !== '\n') { i++; }
      continue;
    }
    if (c === '"') { inStr = true; }
    out += c; i++;
  }
  out = out.replace(/[\u0000-\u001f\u007f]/g, '');
  out = out.replace(/,(\s*[\]}])/g, '$1');  // 剥尾逗号（JSON5 宽松，影视仓源实测使用）
  return JSON.parse(out) as Record<string, Object>;
}

// 整体 base64 层：可能带盐前缀，试偏移 0..16；成功返回解析对象，失败返回 null
function fromB64Maybe(text: string): Record<string, Object> | null {
  for (let skip = 0; skip <= 16; skip++) {
    const body = stripNonB64(text.substring(skip));
    if (body.length < 4 || body.length % 4 === 1) { continue; }
    try {
      return parseJson5ish(utf8Decode(b64decode(body)));
    } catch (e) { /* 试下一偏移 */ }
  }
  return null;
}

// 从尾部向前找 JPEG 结束符 FFD9，返回其后第一个字节下标；找不到返回 -1
function findJpegEnd(b: Uint8Array): number {
  for (let i = b.length - 2; i >= 0; i--) {
    if (b[i] === 0xff && b[i + 1] === 0xd9) { return i + 2; }
  }
  return -1;
}

/**
 * 订阅内容四层解码链：纯 JSON5 → 整体 base64（试盐偏移 0..16）→ JPEG 尾部 steg（FFD9 定位）。
 * 每层失败进入下一层，全部失败抛 ConfigDecodeError。
 */
export function decodeConfigContent(input: string | Uint8Array): TvboxConfig {
  const text = typeof input === 'string' ? input : utf8Decode(input);
  // 1) 纯 JSON/JSON5
  try { return parseTvboxConfig(parseJson5ish(text)); } catch (e) { /* 下探 */ }
  // 2) 整体 base64（可能带盐）
  const fromB64 = fromB64Maybe(text);
  if (fromB64 !== null) { return parseTvboxConfig(fromB64); }
  // 3) JPEG 尾部 steg（FFD9 之后藏 10 字符盐 + base64 配置）
  if (typeof input !== 'string') {
    const end = findJpegEnd(input);
    if (end > 0 && end < input.length) {
      const tailText = utf8Decode(input.slice(end));
      const steg = fromB64Maybe(tailText);
      if (steg !== null) { return parseTvboxConfig(steg); }
    }
  }
  throw new ConfigDecodeError('无法识别的订阅内容格式');
}
