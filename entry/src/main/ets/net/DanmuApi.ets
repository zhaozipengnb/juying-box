// 弹弹play 开放 API 封装:片名匹配 → 弹幕拉取。
// 鉴权:官方要求 X-AppId/X-Timestamp/X-Signature 三头,签名 =
// Base64(HMAC-SHA256(appSecret, appId + timestamp + method + path + body))。
// AppId/Secret 在弹弹play 开放平台免费申请,由设置页填入(AppSettings.dandanAppId/dandanSecret)。
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { httpFetch } from './HttpClient';
import { AppSettings } from '../state/AppSettings';

export interface DanmuItem {
  t: number;      // 出现时间(秒)
  text: string;   // 内容
  color: string;  // #RRGGBB
}

export interface DanmuEpisode {
  episodeId: number;
  animeTitle: string;
  episodeTitle: string;
}

const BASE = 'https://api.dandanplay.net';
const TAG = 'OKV-DANMU';

function bytesOf(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

// 弹弹play 请求签名:HMAC-SHA256(secret, appId+timestamp+method+path+body) → Base64
async function sign(appId: string, secret: string, timestamp: string, method: string,
  path: string, body: string): Promise<string> {
  const msg = appId + timestamp + method + path + body;
  const gen = cryptoFramework.createSymKeyGenerator('HMAC');
  const kb: cryptoFramework.DataBlob = { data: bytesOf(secret) };
  const key = gen.convertKeySync(kb);   // HMAC 原始密钥注入
  const mac = cryptoFramework.createMac('SHA256');
  await mac.init(key);
  await mac.update({ data: bytesOf(msg) });
  const out = await mac.doFinal();
  return new util.Base64Helper().encodeToStringSync(out.data);
}

// UTC 时间戳 yyyy-MM-ddTHH:mm:ss.fffZ(官方要求格式,毫秒三段固定)
function utcStamp(): string {
  const n = new Date();
  const p = (v: number, w: number): string => String(v).padStart(w, '0');
  return `${n.getUTCFullYear()}-${p(n.getUTCMonth() + 1, 2)}-${p(n.getUTCDate(), 2)}` +
    `T${p(n.getUTCHours(), 2)}:${p(n.getUTCMinutes(), 2)}:${p(n.getUTCSeconds(), 2)}` +
    `.${p(n.getUTCMilliseconds(), 3)}Z`;
}

async function signedFetch(method: string, path: string, body: string): Promise<string> {
  const st = AppSettings.instance;
  const appId = st.dandanAppId.trim();
  const secret = st.dandanSecret.trim();
  if (appId === '' || secret === '') {
    throw new Error('未配置弹弹play AppId/Secret');
  }
  const timestamp = utcStamp();
  const sig = await sign(appId, secret, timestamp, method, path, body);
  const resp = await httpFetch(BASE + path, {
    method: method,
    headers: {
      'User-Agent': 'okhttp/4.9.3',
      'Content-Type': 'application/json',
      'X-AppId': appId,
      'X-Timestamp': timestamp,
      'X-Signature': sig
    },
    timeoutMs: 15000
  });
  const text = resp.text();
  if (resp.status !== 200) {
    throw new Error(`弹弹play ${resp.status}: ${text.substring(0, 120)}`);
  }
  return text;
}

// 片名匹配:fileName 建议 "片名 集名.mp4" 形态;返回匹配到的集(按序,由调用方挑)
export async function danmuMatch(fileName: string): Promise<DanmuEpisode[]> {
  const body = JSON.stringify({ fileName: fileName });
  const text = await signedFetch('POST', '/api/v2/match', body);
  const obj = JSON.parse(text) as Record<string, Object>;
  const matched = obj['matched'] as boolean ?? false;
  if (!matched) { return []; }
  const epsRaw = obj['episodes'] as Object[] ?? [];
  const eps: DanmuEpisode[] = [];
  for (const e of epsRaw) {
    const r = e as Record<string, Object>;
    eps.push({
      episodeId: r['episodeId'] as number ?? 0,
      animeTitle: r['animeTitle'] as string ?? '',
      episodeTitle: r['episodeTitle'] as string ?? ''
    });
  }
  return eps;
}

// 手动搜索(匹配不准时用):按番剧名搜索 → 番剧列表(含每集)
export async function danmuSearch(keyword: string): Promise<DanmuEpisode[]> {
  const path = `/api/v2/search/episodes?animeTitle=${encodeURIComponent(keyword)}`;
  const text = await signedFetch('GET', path, '');
  const obj = JSON.parse(text) as Record<string, Object>;
  const animes = obj['animes'] as Object[] ?? [];
  const eps: DanmuEpisode[] = [];
  for (const a of animes) {
    const ar = a as Record<string, Object>;
    const title = ar['animeTitle'] as string ?? '';
    const items = ar['episodes'] as Object[] ?? [];
    for (const e of items) {
      const er = e as Record<string, Object>;
      eps.push({
        episodeId: er['episodeId'] as number ?? 0,
        animeTitle: title,
        episodeTitle: er['episodeTitle'] as string ?? ''
      });
    }
  }
  return eps;
}

// 拉取弹幕(含关联库),解析为 {时间,内容,颜色} 列表(按时间升序)
export async function danmuComments(episodeId: number): Promise<DanmuItem[]> {
  const text = await signedFetch('GET', `/api/v2/comment/${episodeId}?withRelated=true`, '');
  const obj = JSON.parse(text) as Record<string, Object>;
  const raw = obj['comments'] as Object[] ?? [];
  const items: DanmuItem[] = [];
  for (const c of raw) {
    const r = c as Record<string, Object>;
    const t = r['m'] as string ?? '';
    const p = r['p'] as string ?? '';
    // p = "时间秒,模式(1滚动/4底/5顶),颜色十进制,来源…"
    const parts = p.split(',');
    if (parts.length < 3 || t === '') { continue; }
    const sec = parseFloat(parts[0]);
    if (isNaN(sec) || sec < 0) { continue; }
    const colorNum = parseInt(parts[2]);
    const color = isNaN(colorNum) ? '#FFFFFF' :
      '#' + (colorNum & 0xFFFFFF).toString(16).padStart(6, '0').toUpperCase();
    items.push({ t: sec, text: t, color: color });
  }
  items.sort((a: DanmuItem, b: DanmuItem): number => a.t - b.t);
  return items;
}
