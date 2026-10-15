// IDN 域名转码：中文等非 ASCII 域名 → punycode（RFC 3492），供网络层使用。
// 场景：模拟器/部分设备 DNS 不解析中文域名（如「影视仓.com」），转 xn--xxxx 形式后可解析。

const BASE = 36;
const TMIN = 1;
const TMAX = 26;
const SKEW = 38;
const DAMP = 700;
const INITIAL_BIAS = 72;
const INITIAL_N = 128; // 0x80

// punycode 数字 → ASCII（0-25→a-z，26-35→0-9）
function encodeDigit(d: number): string {
  return d < 26 ? String.fromCharCode(97 + d) : String.fromCharCode(48 + d - 26);
}

function adapt(delta: number, numPoints: number, firstTime: boolean): number {
  delta = firstTime ? Math.floor(delta / DAMP) : Math.floor(delta / 2);
  delta += Math.floor(delta / numPoints);
  let k = 0;
  while (delta > ((BASE - TMIN) * TMAX) / 2) {
    delta = Math.floor(delta / (BASE - TMIN));
    k += BASE;
  }
  return k + Math.floor(((BASE - TMIN + 1) * delta) / (delta + SKEW));
}

// 单个 label 的 punycode 编码（输入为码点数组，返回 xn-- 前缀的 ASCII 串）
function punycodeLabel(input: number[]): string {
  let output = '';
  const basicLen = input.filter((cp: number): boolean => cp < INITIAL_N).length;
  for (const cp of input) {
    if (cp < INITIAL_N) { output += String.fromCharCode(cp); }
  }
  let h = basicLen;
  let bias = INITIAL_BIAS;
  let delta = 0;
  let n = INITIAL_N;
  if (basicLen > 0) { output += '-'; }
  while (h < input.length) {
    let m = 0x10FFFF;
    for (const cp of input) {
      if (cp >= n && cp < m) { m = cp; }
    }
    delta += (m - n) * (h + 1);
    n = m;
    for (const cp of input) {
      if (cp < n) { delta++; }
      if (cp === n) {
        let q = delta;
        let k = BASE;
        let t = 0;
        while (true) {
          t = k <= bias ? TMIN : (k >= bias + TMAX ? TMAX : k - bias);
          if (q < t) { break; }
          output += encodeDigit(t + Math.floor((q - t) % (BASE - t)));
          q = Math.floor((q - t) / (BASE - t));
          k += BASE;
        }
        output += encodeDigit(q);  // RFC 3492：q<t 退出循环后剩余 q 直接作为数字输出
        bias = adapt(delta, h + 1, h === basicLen);
        delta = 0;
        h++;
      }
    }
    delta++;
    n++;
  }
  return 'xn--' + output;
}

function labelNeedsPunycode(label: string): boolean {
  for (let i = 0; i < label.length; i++) {
    if (label.charCodeAt(i) > 127) { return true; }
  }
  return false;
}

// URL 中的中文域名转 punycode（其余部分原样）；无变化时原样返回
export function toPunycodeUrl(url: string): string {
  const schemeIdx = url.indexOf('://');
  if (schemeIdx < 0) { return url; }
  const hostStart = schemeIdx + 3;
  let hostEnd = hostStart;
  while (hostEnd < url.length && url.charAt(hostEnd) !== '/' && url.charAt(hostEnd) !== '?' && url.charAt(hostEnd) !== '#') { hostEnd++; }
  const hostWithPort = url.substring(hostStart, hostEnd);
  if (!labelNeedsPunycode(hostWithPort)) { return url; }
  const portIdx = hostWithPort.lastIndexOf(':');
  const host = portIdx > 0 ? hostWithPort.substring(0, portIdx) : hostWithPort;
  const port = portIdx > 0 ? hostWithPort.substring(portIdx) : '';
  const labels = host.split('.');
  const out: string[] = [];
  for (const label of labels) {
    if (label.length === 0) { out.push(label); continue; }
    const codePoints: number[] = [];
    for (const ch of label) { codePoints.push(ch.codePointAt(0) ?? 63); }
    out.push(labelNeedsPunycode(label) ? punycodeLabel(codePoints) : label);
  }
  return url.substring(0, hostStart) + out.join('.') + port + url.substring(hostEnd);
}
