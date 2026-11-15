// 弹幕数据源:B站匿名链路(零配置,无需任何账号/输入)。
// 链路:匿名取 wbi 签名密钥 → 签名搜索片名 → 候选按播放数排序 → 分P列表按集对齐 → 弹幕 XML。
// 弹幕 list.so 返回原始 deflate 压缩的 XML——ArkTS zlib 只支持文件级解压,
// 借常驻 ArkWeb 容器的 DecompressionStream('deflate-raw') 解压(浏览器原生能力)。
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { httpFetch } from './HttpClient';
import { utf8Decode } from 'common';
import { WebFetchBridge } from './WebFetchBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DTAG = 'OKV-DANMU';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';

export interface DanmuItem {
  t: number;      // 出现时间(秒)
  text: string;   // 内容
  color: string;  // #RRGGBB
  mode: number;   // 1=滚动 4=底部固定 5=顶部固定(其余按滚动处理)
}

// wbi 签名用置换表(B站公开算法)
const MIXIN_TAB: number[] = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
  26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52];

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

// buvid3 必须是 UUID 形态:B站风控对非法格式直接回空体(弹幕拉不到的根因之一)
function biliCookie(): string {
  let h = '';
  for (let i = 0; i < 32; i++) { h += Math.floor(Math.random() * 16).toString(16); }
  return 'buvid3=' + `${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20, 32)}`;
}

async function biliGet(url: string): Promise<Uint8Array> {
  const r = await httpFetch(url, {
    headers: {
      'User-Agent': UA,
      'Referer': 'https://www.bilibili.com',
      'Cookie': biliCookie()
    }
  });
  return new Uint8Array(r.body);
}

async function biliWbiKey(): Promise<string> {
  const bytes = await biliGet('https://api.bilibili.com/x/web-interface/nav');
  const nav = JSON.parse(utf8Decode(bytes)) as Record<string, Object>;
  const wbi = ((nav['data'] ?? {}) as Record<string, Object>)['wbi_img'] as Record<string, Object>;
  const img = biliNameOf(wbi['img_url'] as string);
  const sub = biliNameOf(wbi['sub_url'] as string);
  return biliMixinKey(img, sub);
}

// 搜索结果完整列表(按播放数降序)——弹幕面板手动选库用
export async function biliSearchList(keyword: string): Promise<BiliSearchItem[]> {
  const mixin = await biliWbiKey();
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
  const out: BiliSearchItem[] = [];
  for (const r of results) {
    const rr = r as Record<string, Object>;
    out.push({
      bvid: rr['bvid'] as string ?? '',
      title: ((rr['title'] as string) ?? '').replace(/<[^>]+>/g, ''),
      play: parseInt(rr['play'] as string ?? '0') || 0
    });
  }
  out.sort((a: BiliSearchItem, b: BiliSearchItem): number => b.play - a.play);
  return out;
}

// wbi 签名搜索:返回候选 bvid 列表(有序:标题含片名核心词的播放王在前,全局播放王兜底)
async function biliCandidates(keyword: string, mixin: string): Promise<string[]> {
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
  // 候选打分:标题含片名核心词(前4字)的按播放数最高优先——人看得多的版本才有弹幕;
  // B站模糊搜索结果标题未必包含完整片名(如 Ⅱ 绝世唐门),无相关时兜底取全局播放最高
  let titledBvid = '';
  let bestPlay = -1;
  let bestTitledPlay = -1;
  let globalBvid = '';
  const kw = keyword.split(' ')[0];
  const kwCore = kw.length > 4 ? kw.substring(0, 4) : kw;
  for (const r of results) {
    const rr = r as Record<string, Object>;
    const title = ((rr['title'] as string) ?? '').replace(/<[^>]+>/g, '');
    const play = parseInt(rr['play'] as string ?? '0') || 0;
    if (play > bestPlay) {
      bestPlay = play;
      globalBvid = rr['bvid'] as string ?? '';
    }
    if (kwCore !== '' && title.indexOf(kwCore) >= 0 && play > bestTitledPlay) {
      bestTitledPlay = play;
      titledBvid = rr['bvid'] as string ?? '';
    }
  }
  const out: string[] = [];
  if (titledBvid !== '') { out.push(titledBvid); }
  if (globalBvid !== '' && globalBvid !== titledBvid) { out.push(globalBvid); }
  hilog.info(0x0000, DTAG, 'candidates: %{public}s (titled=%{public}d global=%{public}d)',
    out.join(','), bestTitledPlay, bestPlay);
  return out;
}

// 搜索结果条目(弹幕面板手选库用)
export interface BiliSearchItem {
  bvid: string;
  title: string;
  play: number;
}

// 分P列表:返回 {cid, part} 数组(匿名)
export interface BiliPage {
  cid: number;
  part: string;
}

export async function biliPagelist(bvid: string): Promise<BiliPage[]> {
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

// 弹幕 XML(原始 deflate):取回字节 → base64 → 经 ArkWeb DecompressionStream 解压。
// 部分 HTTP 栈会自动解压(响应即 XML),两种形态都兼容
async function biliDanmuXml(oid: number): Promise<string> {
  const bytes = await biliGet(`https://api.bilibili.com/x/v1/dm/list.so?oid=${oid}`);
  hilog.info(0x0000, DTAG, 'danmu raw %{public}d bytes', bytes.length);
  if (bytes.length < 4) { return ''; }
  const head = utf8Decode(bytes.subarray(0, 8));
  if (head.startsWith('<?xml') || head.startsWith('<i>') || head.startsWith('<i ')) {
    return utf8Decode(bytes);   // HTTP 栈已自动解压
  }
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

// 按 cid 直接取弹幕列表(面板手选分P用)
export async function biliDanmuByCid(oid: number): Promise<DanmuItem[]> {
  const xml = await biliDanmuXml(oid);
  if (xml === '') { return []; }
  return parseDanmuXml(xml);
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
      const modeNum = parseInt(parts[1]);
      items.push({
        t: sec,
        text: m[2],
        color: isNaN(colorNum) ? '#FFFFFF' : '#' + (colorNum & 0xFFFFFF).toString(16).padStart(6, '0').toUpperCase(),
        mode: isNaN(modeNum) ? 1 : modeNum
      });
    }
    m = re.exec(xml);
  }
  items.sort((a: DanmuItem, b: DanmuItem): number => a.t - b.t);
  return items;
}

// 分P对齐:集号一致优先,其次同名,再退到集序/第 1 页
async function biliPickCid(pages: BiliPage[], epName: string, epIdx: number): Promise<number> {
  const num = epNumberOf(epName);
  for (const p of pages) {
    if (num >= 0 && epNumberOf(p.part) === num) { return p.cid; }
    if (p.part === epName) { return p.cid; }
  }
  return pages[Math.min(epIdx, pages.length - 1)].cid;
}

// ===== 对外入口:片名+集名+集序 → 弹幕列表(零配置) =====
// 逐候选尝试:标题最佳的可能是 0 弹幕的解说/新上传,此时回退全局播放王候选
export async function biliDanmu(movieName: string, epName: string, epIdx: number): Promise<DanmuItem[]> {
  hilog.info(0x0000, DTAG, 'bili start: movie=%{public}s ep=%{public}s', movieName, epName);
  const mixin = await biliWbiKey();
  const cands = await biliCandidates(movieName, mixin);
  for (const bvid of cands) {
    const pages = await biliPagelist(bvid);
    if (pages.length === 0) { continue; }
    const cid = await biliPickCid(pages, epName, epIdx);
    const xml = await biliDanmuXml(cid);
    if (xml === '') { continue; }
    const items = parseDanmuXml(xml);
    if (items.length > 0) {
      hilog.info(0x0000, DTAG, 'bili hit %{public}s: %{public}d danmaku', bvid, items.length);
      return items;
    }
    hilog.info(0x0000, DTAG, 'bili %{public}s has no danmaku, try next candidate', bvid);
  }
  return [];
}

// ===== 弹弹play 聚合源:凭据内置(开发者去 api.dandanplay.net 免费申请一次,填进下面两个常量) =====
// 为空时自动只用B站匿名弹幕,用户端零配置
const DANDAN_APP_ID: string = '';
const DANDAN_SECRET: string = '';

// 官方签名模式(doc.dandanplay.com/open):X-Signature = base64(SHA256(AppId + Timestamp + Path + AppSecret))
// Path = 接口路径(小写、以/开头、不含 ? 及查询参数);Timestamp 为 UTC 秒级,机器时钟偏差会签名失败
async function dandanSign(appId: string, ts: string, path: string, secret: string): Promise<string> {
  const md = cryptoFramework.createMd('SHA256');
  const msg: cryptoFramework.DataBlob = { data: bytesOf(appId + ts + path + secret) };
  await md.update(msg);
  const out = await md.digest();
  return new util.Base64Helper().encodeToStringSync(out.data);
}

// path 参与签名(不含查询串),query 为 '?xxx' 原样拼在 URL 上
async function dandanGet(path: string, query: string, appId: string, secret: string): Promise<string> {
  const ts = Math.floor(Date.now() / 1000).toString();
  const sig = await dandanSign(appId, ts, path, secret);
  const r = await httpFetch(`https://api.dandanplay.net${path}${query}`, {
    headers: {
      'Accept': 'application/json',
      'User-Agent': UA,
      'X-AppId': appId,
      'X-Timestamp': ts,
      'X-Signature': sig
    }
  });
  return utf8Decode(new Uint8Array(r.body));
}

// 搜 episode → 选标题最贴合的 match → 按集号对齐分集(对不上按集序) → 拉弹幕转 DanmuItem
// 两个搜索接口兜底:/api/v2/search/episode(返回 matches) 与 /api/v2/search(返回 animes,解析兼容)
export async function dandanDanmu(movieName: string, epName: string, epIdx: number): Promise<DanmuItem[]> {
  if (DANDAN_APP_ID === '' || DANDAN_SECRET === '') { return []; }
  hilog.info(0x0000, DTAG, 'dandan start: %{public}s ep=%{public}s', movieName, epName);
  const epNum = epNumberOf(epName);
  const kwCore = movieName.length > 4 ? movieName.substring(0, 4) : movieName;

  // 一轮"搜索→选番剧→选分集→拉弹幕":path 为搜索接口(参与签名,不含查询串)
  const grab = async (path: string, kw: string): Promise<DanmuItem[]> => {
    const raw = await dandanGet(path, `?keyword=${encodeURIComponent(kw)}`, DANDAN_APP_ID, DANDAN_SECRET);
    const obj = JSON.parse(raw) as Record<string, Object>;
    const matches = (obj['matches'] ?? obj['animes'] ?? []) as Object[];
    if (matches.length === 0) { return []; }
    // 标题最贴合:含片名核心词(前4字)的 match 优先
    let best: Record<string, Object> | null = null;
    for (const m of matches) {
      const mm = m as Record<string, Object>;
      if (best === null) { best = mm; continue; }
      if (kwCore === '') { continue; }
      const title = mm['animeTitle'] as string ?? '';
      const bestTitle = best['animeTitle'] as string ?? '';
      if (title.indexOf(kwCore) >= 0 && bestTitle.indexOf(kwCore) < 0) { best = mm; }
    }
    const eps = (best !== null ? (best['episodes'] ?? []) : []) as Object[];
    if (eps.length === 0) { return []; }
    let epId = -1;
    for (const e of eps) {
      const ee = e as Record<string, Object>;
      if (epNum >= 0 && epNumberOf(ee['episodeTitle'] as string ?? '') === epNum) {
        epId = ee['episodeId'] as number;
        break;
      }
    }
    if (epId < 0) {
      epId = (eps[Math.min(epIdx, eps.length - 1)] as Record<string, Object>)['episodeId'] as number;
    }
    // withRelated=true:整合第三方站源弹幕——弹弹play 的聚合价值就在这个开关
    const crawl = await dandanGet(`/api/v2/comment/${epId}`, '?withRelated=true', DANDAN_APP_ID, DANDAN_SECRET);
    const cobj = JSON.parse(crawl) as Record<string, Object>;
    const comments = (cobj['comments'] ?? []) as Object[];
    const items: DanmuItem[] = [];
    for (const c of comments) {
      const cc = c as Record<string, Object>;
      const p = (cc['p'] as string ?? '').split(',');
      const tSec = parseFloat(p[0]);
      const modeN = parseInt(p[1]);
      const colorN = parseInt(p[2]);
      const text = cc['m'] as string ?? '';
      if (isNaN(tSec) || text === '') { continue; }
      items.push({
        t: tSec, text: text,
        color: isNaN(colorN) ? '#FFFFFF' : '#' + (colorN & 0xFFFFFF).toString(16).padStart(6, '0').toUpperCase(),
        mode: isNaN(modeN) ? 1 : modeN
      });
    }
    items.sort((a: DanmuItem, b: DanmuItem): number => a.t - b.t);
    if (items.length > 0) { hilog.info(0x0000, DTAG, 'dandan hit ep%{public}d: %{public}d danmaku', epId, items.length); }
    return items;
  };

  const tries: string[] = [];
  if (epNum >= 0) { tries.push(`${movieName} 第${epNum}集`, `${movieName} ${epNum}`); }
  tries.push(movieName);
  for (const kw of tries) {
    try {
      const items = await grab('/api/v2/search/episode', kw);
      if (items.length > 0) { return items; }
    } catch (e) {
      hilog.error(0x0000, DTAG, 'dandan fail kw=%{public}s: %{public}s', kw, e instanceof Error ? e.message : String(e));
    }
  }
  try {
    const items = await grab('/api/v2/search', movieName);
    if (items.length > 0) { return items; }
  } catch (e) {
    hilog.error(0x0000, DTAG, 'dandan fallback fail: %{public}s', e instanceof Error ? e.message : String(e));
  }
  return [];
}

// ===== LogVar danmu_api 聚合源(免费,自部署):爱优腾芒哔咪人韩巴狐乐西埋帆红,dandanplay 兼容协议 =====
// 部署(huangxd-/danmu_api 到 Vercel/Cloudflare/Node,免费)后把地址填进常量,如 https://danmu-api-xxx.vercel.app
// 留空时自动跳过。匿名可调(部署未改 TOKEN 时),无需签名
const DANMU_API_BASE: string = '';

async function httpGetText(url: string): Promise<string> {
  const r = await httpFetch(url, { headers: { 'User-Agent': UA, 'Accept': 'application/json' } });
  return utf8Decode(new Uint8Array(r.body));
}

// 选标题最贴合的 match(含片名核心词前4字的优先)
function pickBestAnime(list: Object[], kwCore: string): Record<string, Object> | null {
  let best: Record<string, Object> | null = null;
  for (const m of list) {
    const mm = m as Record<string, Object>;
    if (best === null) { best = mm; continue; }
    if (kwCore === '') { continue; }
    const title = mm['animeTitle'] as string ?? '';
    const bestTitle = best['animeTitle'] as string ?? '';
    if (title.indexOf(kwCore) >= 0 && bestTitle.indexOf(kwCore) < 0) { best = mm; }
  }
  return best;
}

// 按集号对齐分集,对不上按集序兜底,返回 commentId(=episodeId)
function pickEpisodeId(eps: Object[], epNum: number, epIdx: number): number {
  for (const e of eps) {
    const ee = e as Record<string, Object>;
    if (epNum >= 0 && epNumberOf(ee['episodeTitle'] as string ?? '') === epNum) {
      return ee['episodeId'] as number;
    }
  }
  return (eps[Math.min(Math.max(epIdx, 0), eps.length - 1)] as Record<string, Object>)['episodeId'] as number;
}

// dandanplay 兼容 comments JSON → DanmuItem(p = "时间,模式,颜色,...", m = 文本)
function parseDanmuComments(comments: Object[]): DanmuItem[] {
  const items: DanmuItem[] = [];
  for (const c of comments) {
    const cc = c as Record<string, Object>;
    const p = (cc['p'] as string ?? '').split(',');
    const tSec = parseFloat(p[0]);
    const modeN = parseInt(p[1]);
    const colorN = parseInt(p[2]);
    const text = cc['m'] as string ?? '';
    if (isNaN(tSec) || text === '') { continue; }
    items.push({
      t: tSec, text: text,
      color: isNaN(colorN) ? '#FFFFFF' : '#' + (colorN & 0xFFFFFF).toString(16).padStart(6, '0').toUpperCase(),
      mode: isNaN(modeN) ? 1 : modeN
    });
  }
  items.sort((a: DanmuItem, b: DanmuItem): number => a.t - b.t);
  return items;
}

// danmu_api 聚合弹幕:剧名搜 anime(两个搜索接口兜底) → 集号对齐 → 拉弹幕
export async function logvarDanmu(movieName: string, epName: string, epIdx: number): Promise<DanmuItem[]> {
  if (DANMU_API_BASE === '') { return []; }
  hilog.info(0x0000, DTAG, 'logvar start: %{public}s ep=%{public}s', movieName, epName);
  const epNum = epNumberOf(epName);
  const kwCore = movieName.length > 4 ? movieName.substring(0, 4) : movieName;
  const base = DANMU_API_BASE.endsWith('/') ? DANMU_API_BASE.substring(0, DANMU_API_BASE.length - 1) : DANMU_API_BASE;
  const searchPaths: string[] = ['/api/v2/search/anime?keyword=', '/api/v2/search/episodes?anime='];
  for (const sp of searchPaths) {
    try {
      const raw = await httpGetText(`${base}${sp}${encodeURIComponent(movieName)}`);
      const obj = JSON.parse(raw) as Record<string, Object>;
      const animes = (obj['animes'] ?? obj['matches'] ?? []) as Object[];
      if (animes.length === 0) { continue; }
      const best = pickBestAnime(animes, kwCore);
      const eps = (best !== null ? (best['episodes'] ?? []) : []) as Object[];
      if (eps.length === 0) { continue; }
      const epId = pickEpisodeId(eps, epNum, epIdx);
      const crawl = await httpGetText(`${base}/api/v2/comment/${epId}?format=json`);
      const cobj = JSON.parse(crawl) as Record<string, Object>;
      const items = parseDanmuComments((cobj['comments'] ?? []) as Object[]);
      if (items.length > 0) {
        hilog.info(0x0000, DTAG, 'logvar hit ep%{public}d: %{public}d danmaku', epId, items.length);
        return items;
      }
    } catch (e) {
      hilog.error(0x0000, DTAG, 'logvar fail sp=%{public}s: %{public}s', sp, e instanceof Error ? e.message : String(e));
    }
  }
  return [];
}
