/**
 * CmsJsonApi：MacCMS V10 JSON 协议引擎（站点 type 1）
 * 协议：
 *   分类   GET {api}?ac=list                      → { class:[{type_id,type_name}], list:[...] }
 *   列表   GET {api}?ac=videolist&t={tid}&pg={pg}  → { page, pagecount, list:[vod...] }
 *   详情   GET {api}?ac=detail&ids={id}             → { list:[vod...] }
 *   搜索   GET {api}?ac=detail&wd={key}（list 为空时退 ?ac=videolist&wd={key}）
 *   播放串 vod_play_from / vod_play_url 以 $$$ 分线路、# 分集、名称$地址
 */
import { SiteConfig } from '../model/TvboxModels';
import { HomeContent, PageResult, MovieDetail, Movie, Category, Episode, PlayLine } from '../model/VideoModels';
import { FetchText, SiteDriver } from './SiteDriver';
import { toStr, toInt } from '../util/TypeUtil';

// Record<string, Object> 索引取值后归一为 toStr/toInt 可接受的类型
type JsonField = string | number | boolean | undefined;

// JSON 字段取值：用 typeof 收窄做类型归一（运行时兼容 null/缺失字段 → undefined）
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

// 剥 HTML：先剥原始标签，再解码实体；解码可能让转义标签（&lt;img&gt;）复活，故再剥一次
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

export class CmsJsonApi implements SiteDriver {
  private site: SiteConfig;
  private fetchText: FetchText;

  constructor(site: SiteConfig, fetchText: FetchText) {
    this.site = site;
    this.fetchText = fetchText;
  }

  // 播放地址拼装（静态，供 UI 复用）：
  //   绝对 http(s) 地址原样返回；站内根路径（/开头）拼 site.api 的 protocol//host；
  //   相对路径拼 site.api 所在目录。ArkTS 环境不依赖全局 URL 对象，手写字符串解析。
  static resolvePlayUrl(site: SiteConfig, rawUrl: string): string {
    if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) { return rawUrl; }
    const api = site.api;
    const schemeIdx = api.indexOf('//');
    if (schemeIdx < 0) { return rawUrl; }
    const afterScheme = api.substring(schemeIdx + 2);
    const pathStart = afterScheme.indexOf('/');
    const origin = pathStart < 0 ? api : api.substring(0, schemeIdx + 2 + pathStart);
    if (rawUrl.startsWith('/')) { return origin + rawUrl; }
    // 相对路径：取 api 中最后一个 '/' 之前的目录（需越过 origin 内部的 '//')
    const dirEnd = api.lastIndexOf('/');
    const dir = dirEnd > schemeIdx + 1 ? api.substring(0, dirEnd + 1) : origin + '/';
    return dir + rawUrl;
  }

  private async getJson(path: string): Promise<Record<string, Object>> {
    const text = await this.fetchText(`${this.site.api}${path}`, this.site.header);
    return JSON.parse(text) as Record<string, Object>;
  }

  async getHomeContent(): Promise<HomeContent> {
    const obj = await this.getJson('?ac=list');
    const classes = (obj['class'] ?? []) as Record<string, Object>[];
    const categories: Category[] = classes.map((c: Record<string, Object>): Category => {
      return { tid: toStr(field(c, 'type_id'), ''), name: toStr(field(c, 'type_name'), '') };
    });
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return { categories: categories, items: list.map(pickMovie) };
  }

  async categoryContent(tid: string, pg: number): Promise<PageResult> {
    const obj = await this.getJson(`?ac=videolist&t=${tid}&pg=${pg}`);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return {
      page: toInt(field(obj, 'page'), pg),
      pageCount: toInt(field(obj, 'pagecount'), 1),
      items: list.map(pickMovie)
    };
  }

  async detailContent(ids: string[]): Promise<MovieDetail> {
    const obj = await this.getJson(`?ac=detail&ids=${ids.join(',')}`);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    if (list.length === 0) { throw new Error('详情为空'); }
    const v = list[0];
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
          // 无 '$' 分隔时地址为整段，集名用序号
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
    let obj: Record<string, Object> = await this.getJson(`?ac=detail&wd=${encodeURIComponent(key)}`);
    let list: Record<string, Object>[] = (obj['list'] ?? []) as Record<string, Object>[];
    if (list.length === 0) {
      // 部分站点搜索仅支持 ac=videolist，依次退回
      obj = await this.getJson(`?ac=videolist&wd=${encodeURIComponent(key)}`);
      list = (obj['list'] ?? []) as Record<string, Object>[];
    }
    return { page: 1, pageCount: 1, items: list.map(pickMovie) };
  }
}
