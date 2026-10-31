/**
 * LiveSourceParser：直播源解析（纯字符串逻辑）。
 * 支持两种主流格式：
 *   ① m3u：#EXTINF:-1 tvg-name="x" group-title="分组",频道名 \n http://...（无 group 归「未分组」）
 *   ② txt：分组,#genre# 声明行，其后「频道名,地址」行归入该组（主流 iptv txt 格式）
 * 输出按组聚合的频道表；行级容错（坏行跳过），去重不 aggressive（同名频道不同源均保留）。
 */

export interface LiveChannel {
  name: string;
  url: string;
  urls?: string[];   // 多线路（FongMi txt：频道名,url1#url2#url3；url = 首线路）
}

export interface LiveGroup {
  name: string;
  channels: LiveChannel[];
}

// 统一入口：自动识别 m3u / txt
export function parseLiveSource(text: string): LiveGroup[] {
  const t = text.trim();
  if (t === '') { return []; }
  if (t.startsWith('#EXTM3U') || t.indexOf('#EXTINF') >= 0) {
    return parseM3u(t);
  }
  return parseTxt(t);
}

// m3u：#EXTINF 行的 group-title 取组名、逗号后取频道名；下一非注释行为地址
export function parseM3u(text: string): LiveGroup[] {
  const groups: LiveGroup[] = [];
  const findGroup = (name: string): LiveGroup => {
    let g = groups.find((x: LiveGroup): boolean => x.name === name);
    if (g === undefined) {
      g = { name: name, channels: [] };
      groups.push(g);
    }
    return g;
  };
  const lines = text.split(/\r?\n/);
  let pendingName = '';
  let pendingGroup = '';
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t === '') { continue; }
    if (t.startsWith('#EXTINF')) {
      const gt = t.match(/group-title="([^"]*)"/);
      pendingGroup = gt === null ? '' : gt[1];
      const comma = t.indexOf(',');
      pendingName = comma >= 0 ? t.substring(comma + 1).trim() : '';
      continue;
    }
    if (t.startsWith('#')) { continue; }
    if (pendingName !== '' && /^https?:\/\//i.test(t)) {
      findGroup(pendingGroup === '' ? '未分组' : pendingGroup)
        .channels.push({ name: pendingName, url: t, urls: [t] });
    }
    pendingName = '';
    pendingGroup = '';
  }
  return groups.filter((g: LiveGroup): boolean => g.channels.length > 0);
}

// txt：「分组,#genre#」切换组；「频道名,地址」入当前组
export function parseTxt(text: string): LiveGroup[] {
  const groups: LiveGroup[] = [];
  let cur: LiveGroup | null = null;
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t === '' || t.startsWith('#')) { continue; }
    const comma = t.indexOf(',');
    if (comma < 0) { continue; }
    const left = t.substring(0, comma).trim();
    const right = t.substring(comma + 1).trim();
    if (right === '#genre#') {
      let g = groups.find((x: LiveGroup): boolean => x.name === left);
      if (g === undefined) {
        g = { name: left, channels: [] };
        groups.push(g);
      }
      cur = g;
      continue;
    }
    if (/^https?:\/\//i.test(right) || right.indexOf('#') >= 0) {
      if (cur === null) {
        cur = { name: '未分组', channels: [] };
        groups.push(cur);
      }
      // 多线路：url1#url2#url3（每段可选 url$别名，别名暂不展示）
      const urls: string[] = [];
      const parts = right.split('#');
      for (let k = 0; k < parts.length; k++) {
        const seg = parts[k].trim();
        if (!/^https?:\/\//i.test(seg)) { continue; }
        const dollar = seg.indexOf('$');
        urls.push(dollar >= 0 ? seg.substring(0, dollar).trim() : seg);
      }
      if (urls.length === 0) { continue; }
      cur.channels.push({ name: left, url: urls[0], urls: urls });
    }
  }
  return groups.filter((g: LiveGroup): boolean => g.channels.length > 0);
}
