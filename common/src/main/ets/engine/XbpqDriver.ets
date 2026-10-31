/**
 * XbpqDriver：XBPQ 网页规则引擎——把 TVBox 生态的 XBPQ JSON 规则(ext 内嵌)跑成本地引擎。
 * 规则 DSL（`A&&B` = 取 A 之后到 B 之前的片段）：
 *   分类: 名称$id#…（'||' 同 '#'）  分类url: {cateId}/{catePg}/{area}/{by}/{class}/{lang}/{year}/{letter} 模板
 *   列表: 数组 → 每项套 标题/图片/副标题/链接
 *   详情: 线路数组+线路标题 + 播放数组+播放列表+播放标题+播放链接 + 简介
 *   搜索: 搜索url(+{wd}) + 搜索数组/搜索标题/搜索图片/搜索链接/搜索副标题
 *   播放: 链接是 m3u8/mp4 → 直连；否则 parse='1' 交给播放页嗅探（复用既有嗅探链路）
 * 容错：ext 规则普遍不齐——键名有变体（播放组数≈播放数组）、字段缺省（妖妃无列表规则）。
 * 策略：配置规则优先；缺失或验证不通过时，按常见 CMS 模板(stui/mxone/feifei/红果…)候选选择器
 * 对真实页面现场验证取第一个命中的，并缓存到实例规则表。
 * 兼容点：api 的 `[备用地址]` 后缀剥掉；模板占位支持 %7Bxx%7D；请求头 User-Agent$MOBILE_UA。
 */
import { SiteConfig } from '../model/TvboxModels';
import { HomeContent, PageResult, MovieDetail, Movie, Category, Episode, PlayLine } from '../model/VideoModels';
import { FetchText, SiteDriver } from './SiteDriver';

const MOBILE_UA = 'Mozilla/5.0 (Linux; Android 13; M2102K1C) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const PC_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

// 列表/字段选择器的候选（按常见模板族排序，现场验证取首个命中）
const LIST_CANDIDATES: string[] = [
  'stui-vodlist__box&&</a', 'module-item-pic&&</div', 'hl-lazy&&</a', 'video-item&&</a',
  'card-img-bili&&</a', 'public-list-box&&</a', 'myui-vodlist__box&&</a', 'list-img&&</a',
  'href="/voddetail/&&</a'
];
const TITLE_CANDIDATES: string[] = ['title="&&"', 'alt="&&"'];
const PIC_CANDIDATES: string[] = ['data-original="&&"', 'data-src="&&"', 'data-url="&&"', 'src="&&"'];
const LINK_CANDIDATES: string[] = ['href="&&"'];
const LINE_CANDIDATES: string[] = ['hl-tabs-btn&&a>', '<h3&&</h3', 'data-dropdown-value="&&</div', '<img src=&&/h3>'];
const LINENAME_CANDIDATES: string[] = ['>&&<', '&nbsp;&&</', '<span>&&</span>'];
const PLAYARR_CANDIDATES: string[] = [
  'stui-content__playlist&&</ul', 'myui-content__list&&</ul', 'hl-plays-list">&&<div',
  'sort-item&&</div', 'anthology-list-play&&</div'
];
const EP_CANDIDATES: string[] = ['<a&&/a>', '<a&&a>'];
const EPTITLE_CANDIDATES: string[] = ['>&&</a', '>&&<'];
const EPLINK_CANDIDATES: string[] = ['href="&&"'];

// 是否为 XBPQ 规则站：ext 是含「分类url」的 JSON（type1/type4 网页规则站）
export function isXbpqSite(site: SiteConfig): boolean {
  return site.ext.indexOf('分类url') >= 0;
}

// ---------- 截取 DSL ----------

// 字段规则 "A&&B"：A 之后到 B 之前；A/B 缺省分别表示从头/到尾
function cutBetween(text: string, rule: string): string {
  const i = rule.indexOf('&&');
  const left = i < 0 ? rule : rule.substring(0, i);
  const right = i < 0 ? '' : rule.substring(i + 2);
  if (left === '') {
    if (right === '') { return text; }
    const b = text.indexOf(right);
    return b < 0 ? '' : text.substring(0, b);
  }
  const a = text.indexOf(left);
  if (a < 0) { return ''; }
  const s = a + left.length;
  if (right === '') { return text.substring(s); }
  const b = text.indexOf(right, s);
  return b < 0 ? '' : text.substring(s, b);
}

// 数组规则 "A&&B"：重复切 [A..B] 段（含首尾标记，段内再套字段规则）
function cutSlices(text: string, rule: string): string[] {
  const i = rule.indexOf('&&');
  const left = i < 0 ? rule : rule.substring(0, i);
  const right = i < 0 ? '' : rule.substring(i + 2);
  const out: string[] = [];
  if (left === '') { return out; }
  let cur = text.indexOf(left);
  while (cur >= 0) {
    if (right === '') { out.push(text.substring(cur)); break; }
    const end = text.indexOf(right, cur + left.length);
    if (end < 0) { break; }
    out.push(text.substring(cur, end + right.length));
    cur = text.indexOf(left, end + right.length);
  }
  return out;
}

function absUrl(base: string, u: string): string {
  const t = u.trim();
  if (t === '') { return ''; }
  if (/^https?:\/\//i.test(t)) { return t; }
  if (t.startsWith('//')) { return 'http:' + t; }
  if (t.startsWith('/')) {
    const m = base.match(/^[a-zA-Z]+:\/\/[^/]+/);
    return (m === null ? '' : m[0]) + t;
  }
  return base.substring(0, base.lastIndexOf('/') + 1) + t;
}

function isDirectMedia(u: string): boolean {
  return /\.m3u8|\.mp4|\.mkv|\.flv/i.test(u);
}

function clean(s: string): string {
  return s.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim();
}

// 模板填充：直写与 %7Bxx%7D 编码形态都替换，未用占位填空
function fillTemplate(tpl: string, tid: string, pg: number, wd: string): string {
  const keys: string[] = ['cateId', 'catePg', 'wd', 'area', 'by', 'class', 'lang', 'year', 'letter'];
  const vals: string[] = [tid, String(pg), wd, '', '', '', '', '', ''];
  let u = tpl;
  for (let i = 0; i < keys.length; i++) {
    u = u.split('{' + keys[i] + '}').join(vals[i]);
    u = u.split('%7B' + keys[i] + '%7D').join(vals[i]);
    u = u.split('%7b' + keys[i] + '%7d').join(vals[i]);
  }
  return u;
}

// 分类串解析：'电影$dianying#电视剧$dsj'（'||' 同 '#'），空段跳过
function parseCategories(spec: string): Category[] {
  const out: Category[] = [];
  const norm = spec.split('||').join('#');
  for (const seg of norm.split('#')) {
    const t = seg.trim();
    if (t === '') { continue; }
    const d = t.indexOf('$');
    if (d <= 0) { continue; }
    out.push({ name: t.substring(0, d).trim(), tid: t.substring(d + 1).trim() });
  }
  return out;
}

// 播放页 player_aaaa 的 url 多为 encodeURIComponent 编码的直链(MacCMS stui 约定):
// 取花括号配平的 JSON,解出 url 并 decode;失败返回 ''
function extractPlayerUrl(html: string): string {
  const mark = html.indexOf('player_aaaa');
  if (mark < 0) { return ''; }
  const open = html.indexOf('{', mark);
  if (open < 0) { return ''; }
  let depth = 0;
  let end = -1;
  for (let k = open; k < html.length; k++) {
    if (html.charAt(k) === '{') { depth++; }
    else if (html.charAt(k) === '}') {
      depth--;
      if (depth === 0) { end = k + 1; break; }
    }
  }
  if (end < 0) { return ''; }
  try {
    const obj = JSON.parse(html.substring(open, end)) as Record<string, Object>;
    const u = obj['url'];
    if (typeof u !== 'string' || u === '') { return ''; }
    const dec = decodeURIComponent(u);
    return isDirectMedia(dec) ? dec : '';
  } catch (e) { return ''; }
}

export class XbpqDriver implements SiteDriver {
  private site: SiteConfig;
  private fetchText: FetchText;
  private rule: Record<string, string>;   // 规则键值（缺省选择器现场验证后回填缓存）
  private base: string;
  private headers: Record<string, string>;

  constructor(site: SiteConfig, fetchText: FetchText) {
    this.site = site;
    this.fetchText = fetchText;
    this.base = site.api.split('[')[0];
    this.headers = {};
    for (const k of Object.keys(site.header)) { this.headers[k] = site.header[k]; }
    let rule: Record<string, string> = {};
    try {
      const obj = JSON.parse(site.ext) as Record<string, Object>;
      for (const k of Object.keys(obj)) {
        const v = obj[k];
        if (typeof v === 'string') { rule[k] = v; }
      }
    } catch (e) { /* 规则坏按空处理，方法内抛可读错误 */ }
    this.rule = rule;
    const hh = rule['请求头'];
    if (hh !== undefined && hh.indexOf('User-Agent$') >= 0) {
      const v = hh.substring(hh.indexOf('$') + 1);
      const ua = v === 'MOBILE_UA' ? MOBILE_UA : v === 'PC_UA' ? PC_UA : v;
      this.headers['User-Agent'] = ua;
    }
  }

  // 取规则值：配置缺失时给内置别名/候选（数组类规则在 sample 上验证，命中即缓存）
  private arrRule(key: string, sample: string, alts: string[]): string {
    const configured = this.rule[key];
    if (configured !== undefined && configured !== '' && cutSlices(sample, configured).length > 0) {
      return configured;
    }
    const pool = alts.concat(configured !== undefined && configured !== '' ? [configured] : []);
    for (const cand of pool) {
      if (cutSlices(sample, cand).length > 0) { this.rule[key] = cand; return cand; }
    }
    return configured === undefined ? '' : configured;
  }

  private fieldRule(key: string, sample: string, alts: string[]): string {
    const configured = this.rule[key];
    if (configured !== undefined && configured !== '' && cutBetween(sample, configured) !== '') {
      return configured;
    }
    for (const cand of alts) {
      if (cutBetween(sample, cand) !== '') { this.rule[key] = cand; return cand; }
    }
    return configured === undefined ? '' : configured;
  }

  private async getPage(url: string): Promise<string> {
    return this.fetchText(url, this.headers);
  }

  private toItem(seg: string, base: string): Movie {
    const titleRule = this.fieldRule('标题', seg, TITLE_CANDIDATES);
    const picRule = this.fieldRule('图片', seg, PIC_CANDIDATES);
    const linkRule = this.fieldRule('链接', seg, LINK_CANDIDATES);
    const link = linkRule === '' ? '' : cutBetween(seg, linkRule);
    return {
      vodId: absUrl(base, link),
      name: clean(titleRule === '' ? '' : cutBetween(seg, titleRule)),
      pic: absUrl(base, picRule === '' ? '' : cutBetween(seg, picRule)),
      remark: clean(cutBetween(seg, this.rule['副标题'] ?? '')),
      typeName: ''
    };
  }

  private pageOf(items: Movie[], pg: number): PageResult {
    // XBPQ 无页数概念：有数据就假定还有下一页
    return { page: pg, pageCount: items.length > 0 ? pg + 1 : pg, items: items };
  }

  private async listFromListUrl(url: string, pg: number): Promise<PageResult> {
    const html = await this.getPage(url);
    // 数组候选：内置模板族 + 本站搜索数组(同站列表/搜索结构通常一致)
    const searchArr = this.rule['搜索数组'];
    const alts: string[] = searchArr === undefined ? LIST_CANDIDATES : [searchArr].concat(LIST_CANDIDATES);
    const arrRule = this.arrRule('数组', html, alts);
    if (arrRule === '') { throw new Error('未找到可用的列表结构'); }
    const items: Movie[] = [];
    for (const seg of cutSlices(html, arrRule)) {
      const m = this.toItem(seg, url);
      if (m.vodId !== '' && m.name !== '') { items.push(m); }
    }
    if (items.length === 0) { throw new Error('列表解析为空'); }
    return this.pageOf(items, pg);
  }

  async getHomeContent(): Promise<HomeContent> {
    const spec = this.rule['分类'];
    if (spec === undefined || spec === '') { throw new Error('规则缺少「分类」'); }
    const categories = parseCategories(spec);
    if (categories.length === 0) { throw new Error('规则分类为空'); }
    const first = await this.categoryContent(categories[0].tid, 1);
    return { categories: categories, items: first.items };
  }

  async categoryContent(tid: string, pg: number): Promise<PageResult> {
    const tpl = this.rule['分类url'];
    if (tpl === undefined || tpl === '') { throw new Error('规则缺少「分类url」'); }
    const url = absUrl(this.base, fillTemplate(tpl, tid, pg, ''));
    return this.listFromListUrl(url, pg);
  }

  async searchContent(key: string, quick: boolean): Promise<PageResult> {
    const tpl = this.rule['搜索url'];
    if (tpl === undefined || tpl === '') { throw new Error('该站不支持搜索'); }
    // 搜索url 没有 {wd} 占位符 = 规则残缺(搜索永远返回同一页),当不支持处理,避免污染聚合结果
    if (tpl.indexOf('{wd}') < 0 && tpl.indexOf('%7Bwd%7D') < 0 && tpl.indexOf('%7bwd%7d') < 0) {
      throw new Error('该站搜索规则残缺(无关键词占位)');
    }
    const url = absUrl(this.base, fillTemplate(tpl, '', 1, encodeURIComponent(key)));
    let result = await this.searchOnce(url);
    // 标题带品牌尾缀(如「XXX-国产电影精选」)时全名常搜不到,去尾缀用主干名重搜一次
    if (result.items.length === 0 && key.lastIndexOf('-') > 0) {
      const base = key.substring(0, key.lastIndexOf('-'));
      if (base !== '') {
        const retryUrl = absUrl(this.base, fillTemplate(tpl, '', 1, encodeURIComponent(base)));
        const retry = await this.searchOnce(retryUrl);
        if (retry.items.length > 0) { result = retry; }
      }
    }
    return result;
  }

  private async searchOnce(url: string): Promise<PageResult> {
    const html = await this.getPage(url);
    const arrRule = this.arrRule('搜索数组', html, LIST_CANDIDATES);
    if (arrRule === '') { throw new Error('搜索解析为空'); }
    const items: Movie[] = [];
    for (const seg of cutSlices(html, arrRule)) {
      const titleRule = this.fieldRule('搜索标题', seg, TITLE_CANDIDATES);
      const linkRule = this.fieldRule('搜索链接', seg, LINK_CANDIDATES);
      const picRule = this.fieldRule('搜索图片', seg, PIC_CANDIDATES);
      const link = linkRule === '' ? '' : cutBetween(seg, linkRule);
      const m: Movie = {
        vodId: absUrl(url, link),
        name: clean(titleRule === '' ? '' : cutBetween(seg, titleRule)),
        pic: absUrl(url, picRule === '' ? '' : cutBetween(seg, picRule)),
        remark: clean(cutBetween(seg, this.rule['搜索副标题'] ?? '')),
        typeName: ''
      };
      if (m.vodId !== '' && m.name !== '') { items.push(m); }
    }
    if (items.length === 0) { throw new Error('搜索结果为空'); }
    return this.pageOf(items, 1);
  }

  async detailContent(ids: string[]): Promise<MovieDetail> {
    const url = ids.length > 0 ? ids[0] : '';
    if (url === '') { throw new Error('详情地址为空'); }
    const html = await this.getPage(url);
    const titleRule = this.fieldRule('标题', html, TITLE_CANDIDATES);
    const picRule = this.fieldRule('图片', html, PIC_CANDIDATES);
    const movie: Movie = {
      vodId: url,
      name: clean(titleRule === '' ? '' : cutBetween(html, titleRule)),
      pic: absUrl(url, picRule === '' ? '' : cutBetween(html, picRule)),
      remark: '',
      typeName: ''
    };
    const desc = clean(cutBetween(html, this.rule['简介'] ?? ''));
    // 播放块候选含「播放组数」别名(部分规则作者用这个键名)
    const groupAlias = this.rule['播放组数'];
    const playAlts: string[] = groupAlias === undefined ? PLAYARR_CANDIDATES : [groupAlias].concat(PLAYARR_CANDIDATES);
    const lineArrRule = this.arrRule('线路数组', html, LINE_CANDIDATES);
    const playArrRule = this.arrRule('播放数组', html, playAlts);
    if (playArrRule === '') { throw new Error('详情未解析到播放列表'); }
    const lineSegs = lineArrRule === '' ? [] : cutSlices(html, lineArrRule);
    const lineNameRule = this.rule['线路标题'];
    const lineNames: string[] = [];
    for (let i = 0; i < lineSegs.length; i++) {
      const n = lineNameRule === undefined ? '' : clean(cutBetween(lineSegs[i], lineNameRule));
      lineNames.push(n === '' ? '线路' + (i + 1) : n);
    }
    const playSegs = cutSlices(html, playArrRule);
    const epRule = this.fieldRule('播放列表', playSegs[0], EP_CANDIDATES);
    const epTitleRule = this.fieldRule('播放标题', playSegs[0], EPTITLE_CANDIDATES);
    const epLinkRule = this.fieldRule('播放链接', playSegs[0], EPLINK_CANDIDATES);
    if (epRule === '' || epLinkRule === '') { throw new Error('详情未解析到剧集'); }
    const lines: PlayLine[] = [];
    for (let i = 0; i < playSegs.length; i++) {
      const eps: Episode[] = [];
      for (const seg of cutSlices(playSegs[i], epRule)) {
        const epUrl = absUrl(url, cutBetween(seg, epLinkRule));
        if (epUrl === '') { continue; }
        const ep: Episode = { name: clean(cutBetween(seg, epTitleRule)), url: epUrl };
        if (!isDirectMedia(epUrl)) { ep.parse = '1'; }   // 网页播放地址 → 播放页嗅探
        eps.push(ep);
      }
      if (eps.length === 0) { continue; }
      const name = i < lineNames.length ? lineNames[i] : '线路' + (i + 1);
      lines.push({ from: name, episodes: eps });
    }
    if (lines.length === 0) { throw new Error('详情未解析到可播剧集'); }
    // 详情期批量解析真实播放地址:每集播放页提 player_aaaa.url(encodeURIComponent 的 m3u8),
    // 12 路并发;失败的集保留 parse='1' 由播放页嗅探兜底。每线路最多解析 60 集(超长综艺封顶)。
    const jobs: Promise<void>[] = [];
    for (const line of lines) {
      for (let i = 0; i < line.episodes.length && i < 60; i++) {
        const ep = line.episodes[i];
        if (ep.parse !== '1') { continue; }
        const job = (async (): Promise<void> => {
          try {
            const page = await this.getPage(ep.url);
            const real = extractPlayerUrl(page);
            if (real !== '') {
              ep.url = real;
              ep.parse = '0';
            }
          } catch (e) { /* 单集失败保留嗅探兜底 */ }
        })();
        jobs.push(job);
      }
    }
    // 12 路 lane 消费 jobs
    let next = 0;
    const lane = async (): Promise<void> => {
      while (next < jobs.length) {
        const j = jobs[next];
        next++;
        await j;
      }
    };
    const lanes: Promise<void>[] = [];
    for (let i = 0; i < Math.min(12, jobs.length); i++) { lanes.push(lane()); }
    await Promise.all(lanes);
    return { movie: movie, desc: desc, year: '', actor: '', director: '', lines: lines };
  }
}
