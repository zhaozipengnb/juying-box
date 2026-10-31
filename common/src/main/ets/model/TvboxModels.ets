// TVBox 配置模型与解析：字段宽松取值 + ext 统一为 string（object 形态 JSON 序列化为字符串，Spider 期再解）。
import { toInt, toStr } from '../util/TypeUtil';
import { resolveUrl } from '../util/UrlUtil';

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

// 站点引擎形态分类：cms=type1 CMS JSON；xml=type0 MacCMS XML 采集（TVBox 约定 type 0 即 XML）；
// js=type3 drpy JS 插件（api 为 http(s) URL，.py 结尾的 Python 规则除外——JS 运行时跑不了，判 unknown）；
// jar=type3 TVBox JAR spider（api 为 csp_* 类名等非 URL 形态，实体在配置 spider/jar 指向的 Android JAR 内，
// JS 引擎无法执行）；unknown=其余类型。type3 判据是「api 是否为 http(s) URL」而非 csp_ 前缀。
export type SiteEngine = 'cms' | 'xml' | 'js' | 'appys' | 'proxy' | 'jar' | 'unknown';

export function siteEngine(site: SiteConfig): SiteEngine {
  if (site.type === 0) { return 'xml'; }
  if (site.type === 1) { return 'cms'; }
  if (site.type === 3) {
    // builtin:// 为包内 drpy 源（运行时与规则在 rawfile/builtin，经桥本地加载）
    if (/^https?:\/\/.+/i.test(site.api.trim()) || site.api.trim().startsWith('builtin://')) {
      // api 指向 .py 的是 drpy Python 规则（import base.spider），js 运行时无法执行，按不支持处理
      if (/\.py($|\?)/i.test(site.api.trim())) { return 'unknown'; }
      return 'js';
    }
    // csp_AppYs* 且 ext 含 HTTP URL → appys 引擎（tryConvertCspToCms 已将 api 改为 ext 中的 URL、type 改为 4）
    // 其余 csp_* 纯 JAR 爬虫 → proxy 引擎（需配置代理服务器执行 Java 爬虫）
    return 'proxy';
  }
  if (site.type === 4) { return 'appys'; }
  return 'unknown';
}

// 当前引擎（CMS JSON + XML 采集 + drpy JS + AppYs）可驱动的站点
export function isSiteSupported(site: SiteConfig): boolean {
  const e = siteEngine(site);
  return e === 'cms' || e === 'xml' || e === 'js' || e === 'appys' || e === 'proxy';
}

// 站点 api/ext 的相对路径（./ ../ 开头）对订阅 URL 绝对化，就地修改。
// drpy 系订阅常用相对路径引用运行时/插件（如 ./drpy_libs/drpy2.min.js），
// 不解析则被 siteEngine 误判为 JAR 类名。仅处理明确无歧义的相对标记；
// csp_* 类名与绝对 URL 不动，object 形态 ext（已序列化为 '{' 开头的 JSON）天然不命中。
function isRelativeRef(v: string): boolean {
  return v.startsWith('./') || v.startsWith('../');
}

// 尝试从 ext 中提取 HTTP(S) URL（csp_* JAR 源常把真实 API 地址放在 ext 里）
function extractUrlFromExt(ext: string): string {
  const trimmed = ext.trim();
  if (trimmed === '') { return ''; }
  // 纯 URL 形态
  if (/^https?:\/\/.+/i.test(trimmed)) { return trimmed; }
  // JSON 形态：先尝试已知字段名，再用正则在整串中搜索第一个 http(s) URL
  if (trimmed.startsWith('{')) {
    try {
      const obj = JSON.parse(trimmed) as Record<string, Object>;
      const candidates = ['api', 'url', 'host', 'base', 'baseUrl', 'siteUrl', 'surl', 'site', 'endpoint', 'server', 'main'];
      for (const key of candidates) {
        const v = obj[key];
        if (typeof v === 'string' && /^https?:\/\/.+/i.test(v)) { return v; }
      }
    } catch (e) { /* 非 JSON，跳过 */ }
  }
  // 兜底：正则搜索第一个 http(s) URL（覆盖任意字段名或非 JSON 文本）
  const m = trimmed.match(/https?:\/\/[^\s"'\\]+/i);
  return m !== null ? m[0] : '';
}

// csp_* JAR 源兼容：若 ext 中含 HTTP URL，则转为 CMS 或 AppYs 站点。
// csp_AppYs / csp_AppYsV2 → type4 AppYs（路径式 API）；其余 → type1 CMS（best effort）。
// 就地修改 site，返回 true 表示已转换。
export function tryConvertCspToCms(site: SiteConfig): boolean {
  if (site.type !== 3) { return false; }
  if (/^https?:\/\//i.test(site.api.trim()) || site.api.trim().startsWith('builtin://')) { return false; }
  const apiUrl = extractUrlFromExt(site.ext);
  if (apiUrl === '') { return false; }
  // AppYs 系 Spider → type 4（AppYs 引擎）
  if (site.api.startsWith('csp_AppYs')) {
    site.type = 4;
    site.api = apiUrl;
    return true;
  }
  // 其余 csp_* → type 1（CMS，best effort）
  site.type = 1;
  site.api = apiUrl;
  return true;
}

export function resolveSiteUrls(config: TvboxConfig, subUrl: string): void {
  let converted = 0;
  for (const s of config.sites) {
    if (subUrl.trim() !== '') {
      if (isRelativeRef(s.api)) { s.api = resolveUrl(subUrl, s.api); }
      if (isRelativeRef(s.ext)) { s.ext = resolveUrl(subUrl, s.ext); }
    }
    // JAR 源兼容：ext 含 HTTP URL 则转为 CMS
    if (tryConvertCspToCms(s)) {
      converted++;
    } else if (s.type === 3 && !/^https?:\/\//i.test(s.api.trim()) && !s.api.trim().startsWith('builtin://')) {
      // 记录未转换的 csp_* 源，方便排查 ext 内容
      console.info('OKV csp unsupported: key=' + s.key + ' api=' + s.api + ' jar=' + s.jar.substring(0, 80) + ' ext=' + s.ext.substring(0, 200));
    }
  }
  if (converted > 0) {
    console.info('OKV csp->cms converted ' + converted + ' site(s)');
  }
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
