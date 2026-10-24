/**
 * AppYsApi：AppYs V2 CMS 协议引擎（csp_AppYs / csp_AppYsV2 JAR 源兼容）
 * 协议：
 *   分类   GET {api}/index.php/api/v2/home/classify           → { type_list:[{type_id,type_name}] }
 *   列表   GET {api}/index.php/api/v2/home/searchPage?type={tid}&page={pg}  → { list:[vod...] }
 *   详情   GET {api}/index.php/api/v2/home/info?vod_id={id}    → { vod_info:{...} }
 *   搜索   GET {api}/index.php/api/v2/home/search?key={key}&page=1  → { list:[vod...] }
 *   播放串 vod_play_from / vod_play_url 以 $$$ 分线路、# 分集、名称$地址（与 MacCMS 一致）
 */
import { SiteConfig } from '../model/TvboxModels';
import { HomeContent, PageResult, MovieDetail, Movie, Category, Episode, PlayLine } from '../model/VideoModels';
import { FetchText, SiteDriver } from './SiteDriver';
import { toStr, toInt } from '../util/TypeUtil';
import { CmsJsonApi } from './CmsJsonApi';

type JsonField = string | number | boolean | undefined;

function field(v: Record<string, Object>, key: string): JsonField {
  const raw = v[key];
  if (typeof raw === 'string') { return raw; }
  if (typeof raw === 'number') { return raw; }
  if (typeof raw === 'boolean') { return raw; }
  return undefined;
}

function stripTags(s: string): string {
  return s.replace(/<[^>]+>/g, '');
}

function decodeEntities(s: string): string {
  return s.replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').replace(/&quot;/g, '"');
}

function stripHtml(s: string): string {
  return stripTags(decodeEntities(stripTags(s)));
}

function pickMovie(v: Record<string, Object>): Movie {
  return {
    vodId: toStr(field(v, 'vod_id'), ''),
    name: toStr(field(v, 'vod_name'), ''),
    pic: toStr(field(v, 'vod_pic'), ''),
    remark: toStr(field(v, 'vod_remarks'), ''),
    typeName: toStr(field(v, 'type_name'), '')
  };
}

export class AppYsApi implements SiteDriver {
  private site: SiteConfig;
  private fetchText: FetchText;
  private base: string;

  constructor(site: SiteConfig, fetchText: FetchText) {
    this.site = site;
    this.fetchText = fetchText;
    // 去掉尾部斜杠，保证 path 拼接唯一
    this.base = site.api.endsWith('/') ? site.api.substring(0, site.api.length - 1) : site.api;
  }

  private async getJson(path: string): Promise<Record<string, Object>> {
    const text = await this.fetchText(`${this.base}${path}`, this.site.header);
    return JSON.parse(text) as Record<string, Object>;
  }

  async getHomeContent(): Promise<HomeContent> {
    const pair = await Promise.all([
      this.getJson('/index.php/api/v2/home/classify'),
      this.getJson('/index.php/api/v2/home/searchPage?page=1')
    ]);
    const clsObj = pair[0];
    const listObj = pair[1];
    // AppYs 分类在 type_list 字段；部分版本用 class，兼容两者
    const classes = (clsObj['type_list'] ?? clsObj['class'] ?? []) as Record<string, Object>[];
    const categories: Category[] = classes.map((c: Record<string, Object>): Category => {
      return { tid: toStr(field(c, 'type_id'), ''), name: toStr(field(c, 'type_name'), '') };
    });
    const list = (listObj['list'] ?? []) as Record<string, Object>[];
    return { categories: categories, items: list.map(pickMovie) };
  }

  async categoryContent(tid: string, pg: number): Promise<PageResult> {
    const obj = await this.getJson(`/index.php/api/v2/home/searchPage?type=${tid}&page=${pg}`);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return {
      page: toInt(field(obj, 'page'), pg),
      pageCount: toInt(field(obj, 'pagecount'), 1),
      items: list.map(pickMovie)
    };
  }

  async detailContent(ids: string[]): Promise<MovieDetail> {
    const obj = await this.getJson(`/index.php/api/v2/home/info?vod_id=${ids.join(',')}`);
    // AppYs 详情在 vod_info 字段；部分版本用 list[0]，兼容两者
    const vodInfo = obj['vod_info'];
    let v: Record<string, Object>;
    if (vodInfo !== undefined && typeof vodInfo === 'object') {
      v = vodInfo as Record<string, Object>;
    } else {
      const list = (obj['list'] ?? []) as Record<string, Object>[];
      if (list.length === 0) { throw new Error('详情为空'); }
      v = list[0];
    }
    const movie = pickMovie(v);
    const froms = toStr(field(v, 'vod_play_from'), '').split('$$$');
    const groups = toStr(field(v, 'vod_play_url'), '').split('$$$');
    const lines: PlayLine[] = [];
    for (let i = 0; i < froms.length; i++) {
      const eps: Episode[] = [];
      const group = groups[i] ?? '';
      for (const seg of group.split('#')) {
        if (seg === '') { continue; }
        const idx = seg.indexOf('$');
        if (idx > 0) {
          eps.push({ name: seg.substring(0, idx), url: CmsJsonApi.resolvePlayUrl(this.site, seg.substring(idx + 1)) });
        } else if (seg.length > 0) {
          eps.push({ name: `第${eps.length + 1}集`, url: CmsJsonApi.resolvePlayUrl(this.site, seg) });
        }
      }
      if (eps.length > 0) { lines.push({ from: froms[i], episodes: eps }); }
    }
    return {
      movie: movie,
      desc: stripHtml(toStr(field(v, 'vod_content'), '')),
      year: toStr(field(v, 'vod_year'), ''),
      actor: stripHtml(toStr(field(v, 'vod_actor'), '')),
      director: stripHtml(toStr(field(v, 'vod_director'), '')),
      lines: lines
    };
  }

  async searchContent(key: string, quick: boolean): Promise<PageResult> {
    const obj = await this.getJson(`/index.php/api/v2/home/search?key=${encodeURIComponent(key)}&page=1`);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return { page: 1, pageCount: 1, items: list.map(pickMovie) };
  }
}
