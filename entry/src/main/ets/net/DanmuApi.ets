// 弹幕数据源:B站匿名链路(零配置,无需任何账号/输入)。
// 链路:匿名取 wbi 签名密钥 → 签名搜索片名 → 分P列表按集对齐 → 弹幕 XML。
// 弹幕 list.so 返回原始 deflate 压缩的 XML——ArkTS zlib 只支持文件级解压,
// 借常驻 ArkWeb 容器的 DecompressionStream('deflate-raw') 解压(浏览器原生能力)。
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { httpFetch } from './HttpClient';
import { utf8Decode } from 'common';
import { WebFetchBridge } from './WebFetchBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';
const DTAG = 'OKV-DANMU';

export interface DanmuItem {
  t: number;      // 出现时间(秒)
  text: string;   // 内容
  color: string;  // #RRGGBB
}

// wbi 签名用置换表(B站公开算法)
const MIXIN_TAB: number[] = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
  26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52];
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';

function bytesOf(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function biliMixinKey(imgBase: string, subBase: string): string {
  const raw = imgBase + subBase;
  let out = '';
  for (const i of MIXIN_TAB) { out += raw[i]; }
  return out.substring(0, 32);
}

async function md5Hex(s: string): Promise<string> {
  const md = cryptoFramework.createMd('MD5');
  await md.update({ data: bytesOf(s) });
  const out = await md.digest();
  let hex = '';
  for (const b of out.data) { hex += (b & 0xFF).toString(16).padStart(2, '0'); }
  return hex;
}

function biliNameOf(url: string): string {
  const f = url.substring(url.lastIndexOf('/') + 1);
  return f.split('.')[0];
}

function biliFilterValue(v: string): string {
  let out = '';
  for (const c of v) { if (!"!'()*".includes(c)) { out += c; } }
  return out;
}

async function biliGet(url: string): Promise<Uint8Array> {
  const r = await httpFetch(url, {
    headers: {
      'User-Agent': UA,
      'Referer': 'https://www.bilibili.com',
      'Cookie': 'buvid3=INJECT-' + Math.floor(Math.random() * 1e8).toString()
    }
  });
  return new Uint8Array(r.body);
}

// wbi 签名密钥:nav 接口匿名可取,img/sub 文件名拼接后按置换表取前 32 位
async function biliWbiKey(): Promise<string> {
  const bytes = await biliGet('https://api.bilibili.com/x/web-interface/nav');
  const nav = JSON.parse(utf8Decode(bytes)) as Record<string, Object>;
  const wbi = ((nav['data'] ?? {}) as Record<string, Object>)['wbi_img'] as Record<string, Object>;
  const img = biliNameOf(wbi['img_url'] as string);
  const sub = biliNameOf(wbi['sub_url'] as string);
  return biliMixinKey(img, sub);
}

// wbi 签名搜索:标题含片名的第一个视频 → bvid(找不到返回 '')
async function biliSearchBvid(keyword: string, mixin: string): Promise<string> {
  const wts = Math.floor(Date.now() / 1000);
  const params: Record<string, string> = {
    'keyword': biliFilterValue(keyword),
    'search_type': 'video',
    'wts': String(wts)
  };
  const keys = Object.keys(params).sort();
  const qs = keys.map((k: string): string => `${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`).join('&');
  const wRid = await md5Hex(qs + mixin);
  const bytes = await biliGet(`https://api.bilibili.com/x/web-interface/wbi/search/type?${qs}&w_rid=${wRid}`);
  const sr = JSON.parse(utf8Decode(bytes)) as Record<string, Object>;
  const data = (sr['data'] ?? {}) as Record<string, Object>;
  const results = (data['result'] ?? []) as Object[];
  // 同片名候选里选播放数最高的:人看得多的版本才有弹幕(解说/搬运版常是 0 弹幕)
  let bvid = '';
  let bestPlay = -1;
  const kw = keyword.split(' ')[0];
  for (const r of results) {
    const rr = r as Record<string, Object>;
    const title = ((rr['title'] as string) ?? '').replace(/<[^>]+>/g, '');
    if (kw === '' || title.indexOf(kw) < 0) { continue; }
    const play = parseInt(rr['play'] as string ?? '0') || 0;
    if (play > bestPlay) {
      bestPlay = play;
      bvid = rr['bvid'] as string ?? '';
    }
  }
  hilog.info(0x0000, DTAG, 'bili pick bvid=%{public}s play=%{public}d', bvid, bestPlay);
  return bvid;
}

// 分P列表:返回 {cid, part} 数组(匿名)
interface BiliPage {
  cid: number;
  part: string;
}

async function biliPagelist(bvid: string): Promise<BiliPage[]> {
  const bytes = await biliGet(`https://api.bilibili.com/x/player/pagelist?bvid=${bvid}`);
  const pages = ((JSON.parse(utf8Decode(bytes)) as Record<string, Object>)['data'] ?? []) as Object[];
  const out: BiliPage[] = [];
  for (const p of pages) {
    const r = p as Record<string, Object>;
    out.push({ cid: r['cid'] as number, part: r['part'] as string ?? '' });
  }
  return out;
}

// 集号提取("第03集"/"EP3"→3;无数字 -1)
function epNumberOf(name: string): number {
  const m = name.match(/\d+/);
  return m === null ? -1 : parseInt(m[0]);
}

// 弹幕 XML(原始 deflate):取回字节 → base64 → 经 ArkWeb DecompressionStream 解压
async function biliDanmuXml(oid: number): Promise<string> {
  const bytes = await biliGet(`https://api.bilibili.com/x/v1/dm/list.so?oid=${oid}`);
  const b64 = new util.Base64Helper().encodeToStringSync(bytes);
  const script = `(async () => {
    try {
      const bin = Uint8Array.from(atob('${b64}'), (c: string) => c.charCodeAt(0));
      const ds = new DecompressionStream('deflate-raw');
      const stream = new Blob([bin]).stream().pipeThrough(ds);
      const text = await new Response(stream).text();
      window.__evalResult = text;
      window.__evalDone = 1;
    } catch (e) {
      window.__evalResult = '';
      window.__evalDone = 1;
    }
  })();`;
  return WebFetchBridge.instance.evalJs(script);
}

function parseDanmuXml(xml: string): DanmuItem[] {
  const items: DanmuItem[] = [];
  const re = /<d p="([\d.,]+)"[^>]*>([^<]{1,200})<\/d>/g;
  let m: RegExpExecArray | null = re.exec(xml);
  while (m !== null) {
    const parts = m[1].split(',');
    const sec = parseFloat(parts[0]);
    if (!isNaN(sec) && sec >= 0) {
      const colorNum = parseInt(parts[3]);
      items.push({
        t: sec,
        text: m[2],
        color: isNaN(colorNum) ? '#FFFFFF' : '#' + (colorNum & 0xFFFFFF).toString(16).padStart(6, '0').toUpperCase()
      });
    }
    m = re.exec(xml);
  }
  items.sort((a: DanmuItem, b: DanmuItem): number => a.t - b.t);
  return items;
}

// ===== 对外入口:片名+集名+集序 → 弹幕列表(零配置) =====
// 1. wbi 签名搜索片名 → 标题含片名的视频 2. 分P按集号/集名/序对齐 3. 弹幕解压解析
export async function biliDanmu(movieName: string, epName: string, epIdx: number): Promise<DanmuItem[]> {
  hilog.info(0x0000, DTAG, 'bili start: movie=%{public}s ep=%{public}s', movieName, epName);
  const mixin = await biliWbiKey();
  const bvid = await biliSearchBvid(movieName, mixin);
  hilog.info(0x0000, DTAG, 'bili search bvid=%{public}s', bvid);
  if (bvid === '') { return []; }
  const pages = await biliPagelist(bvid);
  hilog.info(0x0000, DTAG, 'bili pages=%{public}d', pages.length);
  if (pages.length === 0) { return []; }
  // 分P对齐:集号一致优先,其次同名,再退到集序/第 1 页
  const num = epNumberOf(epName);
  let cid = -1;
  for (const p of pages) {
    if (num >= 0 && epNumberOf(p.part) === num) { cid = p.cid; break; }
    if (p.part === epName) { cid = p.cid; break; }
  }
  if (cid < 0) { cid = pages[Math.min(epIdx, pages.length - 1)].cid; }
  hilog.info(0x0000, DTAG, 'bili cid=%{public}d', cid);
  const xml = await biliDanmuXml(cid);
  hilog.info(0x0000, DTAG, 'bili xml len=%{public}d', xml.length);
  if (xml === '') { return []; }
  const items = parseDanmuXml(xml);
  hilog.info(0x0000, DTAG, 'bili parsed %{public}d', items.length);
  return items;
}
