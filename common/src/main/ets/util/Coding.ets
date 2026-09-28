/**
 * 纯编码工具：UTF-8 与 Base64（M1 Task 3）
 * 纯逻辑实现，零 @ohos/@kit 依赖，可在 host 本地单测。
 * 函数签名与 M1 计划 Interfaces 块一字不差，供 ConfigDecoder 解码链依赖。
 */

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let cp = s.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) { // 代理对
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) { cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00); i++; }
    }
    if (cp < 0x80) { out.push(cp); }
    else if (cp < 0x800) { out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f)); }
    else if (cp < 0x10000) { out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)); }
    else { out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)); }
  }
  return new Uint8Array(out);
}

export function utf8Decode(b: Uint8Array): string {
  let out = '';
  let i = 0;
  while (i < b.length) {
    const b0 = b[i];
    let cp = b0;
    if (b0 >= 0xf0) { cp = ((b0 & 0x07) << 18) | ((b[i + 1] & 0x3f) << 12) | ((b[i + 2] & 0x3f) << 6) | (b[i + 3] & 0x3f); i += 4; }
    else if (b0 >= 0xe0) { cp = ((b0 & 0x0f) << 12) | ((b[i + 1] & 0x3f) << 6) | (b[i + 2] & 0x3f); i += 3; }
    else if (b0 >= 0xc0) { cp = ((b0 & 0x1f) << 6) | (b[i + 1] & 0x3f); i += 2; }
    else { i += 1; }
    if (cp >= 0x10000) {
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    } else { out += String.fromCharCode(cp); }
  }
  return out;
}

export function stripNonB64(s: string): string {
  let out = '';
  for (const ch of s) { if (B64.indexOf(ch) >= 0 || ch === '=') { out += ch; } }
  return out;
}

export function b64encode(b: Uint8Array): string {
  let out = '';
  for (let i = 0; i < b.length; i += 3) {
    const b0 = b[i];
    const b1 = i + 1 < b.length ? b[i + 1] : 0;
    const b2 = i + 2 < b.length ? b[i + 2] : 0;
    out += B64[b0 >> 2];
    out += B64[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += i + 1 < b.length ? B64[((b1 & 0x0f) << 2) | (b2 >> 6)] : '=';
    out += i + 2 < b.length ? B64[b2 & 0x3f] : '=';
  }
  return out;
}

export function b64decode(s: string): Uint8Array {
  const clean = stripNonB64(s).replace(/=+$/, '');
  const out: number[] = [];
  let acc = 0;
  let bits = 0;
  for (const ch of clean) {
    const v = B64.indexOf(ch);
    if (v < 0) { continue; }
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((acc >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}
