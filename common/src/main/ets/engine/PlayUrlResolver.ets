/**
 * PlayUrlResolver：起播前把「播放页地址」解析成媒体直链，交给 app 内置播放器。
 *
 * TVBox 生态的 vod_play_url 有两类：
 *   1. 媒体直链（m3u8/mp4…）——可直接交给 Video；
 *   2. 网页播放页——MacCMS 的 /play/xxx-1-1.html、/share/<id>，解析接口 https://jx.xx/?url=…，
 *      真实地址藏在页面里的 player_aaaa 配置或 JS 变量里。
 * 第 2 类若原样塞给 Video 必然 onError（早期实现会因此跳到内嵌网页播放器）。此处把真实地址
 * 挖出来，让各源统一走 app 播放器。
 */
import { FetchText } from './SiteDriver';
import { resolveUrl } from '../util/UrlUtil';

const MEDIA_EXT: RegExp = /\.(m3u8|mp4|flv|mkv|ts|m4v|webm|avi|mov)$/i;
// 页面里的地址可能带签名参数（?sign=…），故判扩展名时允许 query/fragment 跟在后面
const MEDIA_PATH: RegExp = /\.(m3u8|mp4|flv|mkv|ts|m4v|webm|avi|mov)(\?|#|$)/i;
const MEDIA_ANY: RegExp = /https?:\/\/[^\s"'<>\\)]+?\.(?:m3u8|mp4|flv|mkv|ts|m4v|webm)(?:\?[^\s"'<>\\)]*)?/i;
// 变量赋值（var main / var videoUrl …）：地址常为相对路径，需对页面地址绝对化
const VAR_ASSIGN: RegExp = /\b(?:main|url|video|vid|play|source|mp4|m3u8)\w*\s*=\s*["']([^"']+)["']/i;
// 引号内含媒体扩展名的相对路径（/2026…/index.m3u8?sign=…）
const MEDIA_REL: RegExp = /["'](\/[^"'\s]*?\.(?:m3u8|mp4|flv|mkv|ts|m4v|webm)(?:\?[^"'\s]*)?)["']/i;

// 是否为可直接播放的媒体地址（只看路径部分：解析接口 ?url=https://…/b.m3u8 不算直链）
export function isDirectMedia(url: string): boolean {
  const u: string = url.trim();
  let path: string = u;
  const q: number = path.indexOf('?');
  if (q >= 0) { path = path.substring(0, q); }
  const h: number = path.indexOf('#');
  if (h >= 0) { path = path.substring(0, h); }
  return MEDIA_EXT.test(path);
}

// 播放页里的地址常被 JS 转义（https:\/\/…、\u002F），HTML 里还可能写成 &amp;，统一还原后再匹配
export function unescapeJsUrl(s: string): string {
  return s.replace(/\\\//g, '/').replace(/\\u002[fF]/g, '/').replace(/&amp;/g, '&');
}

// 解析接口形态 ?url=…（部分站用 v/vid/video）：取出被解析的内部地址
export function unwrapParseQuery(url: string): string {
  const m: RegExpMatchArray | null = url.match(/[?&](?:url|v|vid|video)=([^&#]+)/i);
  if (m === null) { return ''; }
  let inner: string = m[1];
  try { inner = decodeURIComponent(inner); } catch (e) { /* 非法转义则原样使用 */ }
  inner = inner.trim();
  return /^https?:\/\//i.test(inner) ? inner : '';
}

// 同一正则的多次命中里取第一个满足 test 的捕获组：页面常先出现与播放无关的同名赋值
function firstHit(re: RegExp, s: string, test: (v: string) => boolean): string {
  const g: RegExp = new RegExp(re.source, 'gi');
  let m: RegExpExecArray | null = g.exec(s);
  while (m !== null) {
    const v: string = m[1] === undefined ? '' : m[1].trim();
    if (v !== '' && test(v)) { return v; }
    if (g.lastIndex === m.index) { g.lastIndex++; }  // 零长命中防御，避免死循环
    m = g.exec(s);
  }
  return '';
}

// 从播放页 HTML 里取媒体直链；取不到返回 ''
export function extractMediaUrl(html: string, pageUrl: string): string {
  const text: string = unescapeJsUrl(html);
  const isMedia: (v: string) => boolean = (v: string): boolean => MEDIA_PATH.test(v);
  // MacCMS 播放器配置：player_aaaa = {"flag":"lzm3u8","encrypt":"0","url":"https://…/index.m3u8",…}
  const cfg: RegExpMatchArray | null = text.match(/player_[a-z]+\s*=\s*(\{[\s\S]{0,4000}?\})\s*[;<]/i);
  if (cfg !== null) {
    const inner: RegExpMatchArray | null = cfg[1].match(/"url"\s*:\s*"([^"]+)"/i);
    if (inner !== null && isMedia(inner[1])) { return resolveUrl(pageUrl, inner[1].trim()); }
  }
  // var main = "/2026…/index.m3u8?sign=…" 一类赋值
  const asg: string = firstHit(VAR_ASSIGN, text, isMedia);
  if (asg !== '') { return resolveUrl(pageUrl, asg); }
  // <video src> / <source src> / <iframe src>
  const tag: RegExpMatchArray | null = text.match(/<(?:source|video|iframe)[^>]+src=["']([^"']+)["']/i);
  if (tag !== null && isMedia(tag[1])) { return resolveUrl(pageUrl, tag[1].trim()); }
  // 引号内的相对媒体路径
  const rel: string = firstHit(MEDIA_REL, text, (v: string): boolean => v.length > 0);
  if (rel !== '') { return resolveUrl(pageUrl, rel); }
  // 兜底：正文里第一个绝对媒体直链（含 CDN 带签名参数的 m3u8）
  const any: RegExpMatchArray | null = text.match(MEDIA_ANY);
  return any === null ? '' : any[0];
}

/**
 * 解析播放地址：直链原样返回；播放页返回其内部媒体地址；无法确定时原样返回（由调用方兜底）。
 * depth 限制最多下钻两层解析接口，避免相互指向造成死循环。
 */
export async function resolvePlayUrl(url: string, fetchText: FetchText,
  headers?: Record<string, string>, depth: number = 0): Promise<string> {
  const u: string = url.trim();
  if (u === '' || depth >= 2) { return u; }
  if (isDirectMedia(u)) { return u; }
  try {
    const body: string = await fetchText(u, headers);
    const media: string = extractMediaUrl(body, u);
    if (media !== '') { return media; }
    // 解析接口直接吐直链（响应体就是 m3u8 地址）
    if (isDirectMedia(body)) { return body.trim(); }
  } catch (e) { /* 拉取失败：继续尝试剥 url= 参数 */ }
  const inner: string = unwrapParseQuery(u);
  if (inner !== '' && inner !== u) {
    return await resolvePlayUrl(inner, fetchText, headers, depth + 1);
  }
  return u;
}
