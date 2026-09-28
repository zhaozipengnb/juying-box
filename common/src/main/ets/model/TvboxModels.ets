// TVBox 配置模型与解析：字段宽松取值 + ext 统一为 string（object 形态 JSON 序列化为字符串，Spider 期再解）。
import { toInt, toStr } from '../util/TypeUtil';

export interface SiteConfig {
  key: string; name: string; type: number; api: string;
  searchable: number; quickSearch: number; filterable: number;
  timeout: number; playerType: number; jar: string; ext: string;
  header: Record<string, string>;
}
export interface LiveGroupConfig { name: string; type: string; url: string; ua: string; playerType: number }
export interface ParseConfig { name: string; type: string; url: string; ext: string }
export interface TvboxConfig {
  spider: string; wallpaper: string;
  sites: SiteConfig[]; lives: LiveGroupConfig[]; parses: ParseConfig[];
}

export function parseTvboxConfig(raw: Record<string, Object>): TvboxConfig {
  const sitesRaw = (raw['sites'] ?? []) as Record<string, Object>[];
  const livesRaw = (raw['lives'] ?? []) as Record<string, Object>[];
  const parsesRaw = (raw['parses'] ?? []) as Record<string, Object>[];
  const sites: SiteConfig[] = [];
  for (const s of sitesRaw) {
    const extObj = s['ext'];
    const headerRaw = (s['header'] ?? {}) as Record<string, Object>;
    const header: Record<string, string> = {};
    const keys = Object.keys(headerRaw);
    for (const k of keys) { header[k] = toStr(headerRaw[k], ''); }
    sites.push({
      key: toStr(s['key'], ''), name: toStr(s['name'], ''),
      type: toInt(s['type'], 0), api: toStr(s['api'], ''),
      searchable: toInt(s['searchable'], 1), quickSearch: toInt(s['quickSearch'], 1),
      filterable: toInt(s['filterable'], 0), timeout: toInt(s['timeout'], 10) * 1000,
      playerType: toInt(s['playerType'], 0), jar: toStr(s['jar'], ''),
      ext: typeof extObj === 'string' ? extObj as string : JSON.stringify(extObj ?? ''),
      header: header
    });
  }
  const lives: LiveGroupConfig[] = livesRaw.map((l: Record<string, Object>): LiveGroupConfig => {
    return { name: toStr(l['name'], ''), type: toStr(l['type'], '0'), url: toStr(l['url'], ''), ua: toStr(l['ua'], ''), playerType: toInt(l['playerType'], 0) };
  });
  const parses: ParseConfig[] = parsesRaw.map((p: Record<string, Object>): ParseConfig => {
    return { name: toStr(p['name'], ''), type: toStr(p['type'], '0'), url: toStr(p['url'], ''), ext: JSON.stringify((p['ext'] ?? {}) as Record<string, Object>) };
  });
  return { spider: toStr(raw['spider'], ''), wallpaper: toStr(raw['wallpaper'], ''), sites, lives, parses };
}
