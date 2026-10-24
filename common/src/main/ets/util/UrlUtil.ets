import { util } from '@kit.ArkTS';

// 相对 URL 解析：把订阅里 ./ ../ 开头的相对引用对订阅 URL 绝对化。
// ArkTS 环境不依赖全局 URL 对象，手写字符串解析（与 CmsJsonApi 同一约束）。
// 语义对齐 WHATWG URL：绝对引用（含 scheme）、协议相对（//host/..）、根相对（/..）、
// 目录相对（./、../、裸相对）；相对引用整体替换 path 与 query（不继承 base 的 query）。

// base 目录拼接后的路径段归一：合并 ./ ../，保留 query/fragment 随段尾
function normalizePath(p: string): string {
  const q = p.indexOf('?');
  const head = q >= 0 ? p.substring(0, q) : p;
  const tail = q >= 0 ? p.substring(q) : '';
  const out: string[] = [];
  const segs = head.split('/');
  for (let i = 0; i < segs.length; i++) {
    const seg = segs[i];
    if (seg === '' || seg === '.') { continue; }
    if (seg === '..') { out.pop(); continue; }
    out.push(seg);
  }
  return '/' + out.join('/') + tail;
}

// base（绝对 URL）+ ref（相对/绝对引用）→ 绝对 URL。base 非标准形态时原样返回 ref。
export function resolveUrl(base: string, ref: string): string {
  const r = ref.trim();
  if (r === '') { return base; }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(r)) { return r; }
  const b = base.trim();
  if (r.startsWith('//')) {
    const sm = b.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)/);
    return sm === null ? r : sm[1] + r;
  }
  const m = b.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^/?#]+)/i);
  if (m === null) { return r; }
  const schemeHost = m[1] + '//' + m[2];
  if (r.startsWith('/')) { return schemeHost + r; }
  const q = b.indexOf('?');
  const rawPath = (q >= 0 ? b.substring(0, q) : b).substring(schemeHost.length);
  const dir = rawPath.substring(0, rawPath.lastIndexOf('/') + 1);
  return schemeHost + normalizePath(dir + r);
}

// data: URL → 文本（聚合源包内嵌 drpy 规则用）。支持 base64 与 URL 编码两种载荷；
// 非 data: 前缀原样返回（调用方按普通 URL 继续）；缺逗号/解码失败抛错由调用方提示。
export function decodeDataUrl(url: string): string {
  const u = url.trim();
  if (!u.startsWith('data:')) { return url; }
  const comma = u.indexOf(',');
  if (comma < 0) { throw new Error('data: URL 缺少逗号分隔'); }
  const meta = u.substring(5, comma);
  const payload = u.substring(comma + 1);
  if (meta.indexOf(';base64') >= 0) {
    const helper = new util.Base64Helper();
    const bytes = helper.decodeSync(payload);
    return new util.TextDecoder('utf-8').decodeToString(bytes);
  }
  return decodeURIComponent(payload);
}
