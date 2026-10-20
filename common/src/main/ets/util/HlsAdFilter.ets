/**
 * HLS 去广告过滤（纯字符串逻辑，供本地代理服务在起播前改写 m3u8）。
 *
 * 资源站的插播广告形态：#EXT-X-DISCONTINUITY 分块，内容块与广告块时长差异悬殊
 * （内容块通常数分钟，广告块 15~60 秒）。过滤策略按列表结构三选一：
 *   1. 存在时长 > CONTENT_MIN_SEC 的「内容锚点块」→ 剔除 ≤ AD_MAX_SEC 的广告块，
 *      保留块之间补一个 DISCONTINUITY（时间戳跳变仍在）；
 *   2. 无锚点但分块数量 ≥ MERGE_MIN_GROUPS（全是短块）→ 这是人工切块的防采集结构
 *      （实测块间 PTS 连续），直接去掉全部 DISCONTINUITY 标记合并成单流——部分播放器
 *      （HarmonyOS HiStreamer）对大量连续性分块会下载正常但解不出帧，合并后可播；
 *   3. 其余 → 原样放行（仅做地址绝对化）。
 * 无论哪种策略，片段与 KEY/MAP 的相对地址都会对 baseUrl 绝对化——本地代理改写后播放器
 * 拿到的是 127.0.0.1 的播放列表，相对地址必须指向源站 CDN 才能直接拉流。
 * 主播放列表（#EXT-X-STREAM-INF）不判广告，把每条子列表地址经 wrap() 转成本地代理地址。
 */
import { resolveUrl } from './UrlUtil';

// 单块时长 ≤ 此值视为广告块（秒）
export const AD_MAX_SEC: number = 60;
// 存在时长 > 此值的块才启用广告剔除（秒）
export const CONTENT_MIN_SEC: number = 120;
// 全短块列表的分块数 ≥ 此值时判定为人工切块结构，执行合并（小于则原样）
export const MERGE_MIN_GROUPS: number = 8;

// 主播放列表判据：含 STREAM-INF 即为 master（子列表引用而非片段）
export function isMasterPlaylist(text: string): boolean {
  return text.indexOf('#EXT-X-STREAM-INF') >= 0;
}

// 主播放列表：每条子列表地址（非 # 开头的行）绝对化后经 wrap() 转为本地代理地址
export function filterMasterPlaylist(text: string, baseUrl: string, wrap: (u: string) => string): string {
  const lines: string[] = text.split(/\r?\n/);
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const t: string = lines[i].trim();
    if (t === '') { out.push(lines[i]); continue; }
    if (t.startsWith('#')) { out.push(t); continue; }
    out.push(wrap(resolveUrl(baseUrl, t)));
  }
  return out.join('\n');
}

// 媒体播放列表：绝对化 + 按连续性分块去广告
export function filterMediaPlaylist(text: string, baseUrl: string): string {
  const lines: string[] = text.split(/\r?\n/);

  // 播放块：discont=该块前面是否原有 DISCONTINUITY 标记；lines=块内行（含标签）
  interface HlsGroup {
    discont: boolean;
    dur: number;
    lines: string[];
  }
  const groups: HlsGroup[] = [];
  let cur: HlsGroup = { discont: false, dur: 0, lines: [] };
  groups.push(cur);
  for (let i = 0; i < lines.length; i++) {
    const t: string = lines[i].trim();
    if (t === '') { continue; }
    // 注意排除 DISCONTINUITY-SEQUENCE（全局序号标签，不是分块边界）
    if (t.startsWith('#EXT-X-DISCONTINUITY') && !t.startsWith('#EXT-X-DISCONTINUITY-')) {
      cur = { discont: true, dur: 0, lines: [] };
      groups.push(cur);
      continue;
    }
    if (t.startsWith('#EXTINF:')) {
      const d: number = parseFloat(t.substring('#EXTINF:'.length));
      if (!isNaN(d)) { cur.dur += d; }
    }
    if (t.startsWith('#')) { cur.lines.push(absolutizeTagAttrs(t, baseUrl)); continue; }
    // 片段行：绝对化（播放器从本地代理拿到列表后需直接命中源站 CDN）
    cur.lines.push(resolveUrl(baseUrl, t));
  }

  let keep: HlsGroup[] = groups;
  let maxDur: number = 0;
  for (let i = 0; i < groups.length; i++) { maxDur = Math.max(maxDur, groups[i].dur); }
  // 策略选择：有内容锚点 → 剔广告块；全短块且分块多 → 合并去标记；其余原样
  let joinWithDiscont: boolean = true;
  if (groups.length > 1 && maxDur > CONTENT_MIN_SEC) {
    keep = groups.filter((g: HlsGroup): boolean => g.dur > AD_MAX_SEC);
  } else if (groups.length >= MERGE_MIN_GROUPS) {
    keep = groups;
    joinWithDiscont = false;   // 人工切块结构：PTS 连续，去掉标记合成单流
  }

  const out: string[] = [];
  let first: boolean = true;
  for (let i = 0; i < keep.length; i++) {
    const g: HlsGroup = keep[i];
    if (g.lines.length === 0) { continue; }
    if (joinWithDiscont) {
      if (!first || g.discont) { out.push('#EXT-X-DISCONTINUITY'); }   // 块间时间戳跳变标记必须保留
    }
    first = false;
    for (let j = 0; j < g.lines.length; j++) { out.push(g.lines[j]); }
  }
  return out.join('\n');
}

// KEY/MAP 行内的 URI 属性绝对化（相对地址会指向本地代理导致取钥失败）
function absolutizeTagAttrs(line: string, baseUrl: string): string {
  if (!line.startsWith('#EXT-X-KEY') && !line.startsWith('#EXT-X-MAP')) { return line; }
  return line.replace(/URI="([^"]+)"/, (m: string, p1: string): string => {
    return 'URI="' + resolveUrl(baseUrl, p1) + '"';
  });
}

// 统一入口：按列表类型分派；wrap 仅对 master 生效
export function filterHlsPlaylist(text: string, baseUrl: string, wrap: (u: string) => string): string {
  if (isMasterPlaylist(text)) { return filterMasterPlaylist(text, baseUrl, wrap); }
  return filterMediaPlaylist(text, baseUrl);
}
