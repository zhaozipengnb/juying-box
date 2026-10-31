// DrpyDriver：type 3（drpy JS 插件）站点引擎，经 IDrpyBridge 调用 Web 容器内的 drpy 运行时。
// 桥契约（与 DrpyWebBridge 锁定，见 .claude/plans/2026-10-15-drpy-spider.md）：
//   ensureReady(cfg) 懒加载运行时+插件（同 skey 幂等）；call(method, args) 返回 JSON 字符串；
//   method ∈ 'home'|'homeVod'|'category'|'detail'|'play'|'search'，args 均为字符串参数。
// 返回形态与 CMS 同构：home {class,list}；category {list,page,pagecount}；detail {list:[vod...]}；
// play {url,parse,header}；search {list}。vod_play_url 沿用 $$$ 分线路 / # 分集 / 名称$地址 约定。
import { SiteConfig, SiteDriver, CmsJsonApi,
  HomeContent, PageResult, MovieDetail, Movie, Category, Episode, PlayLine,
  toStr, toInt } from 'common';
import { DrpyWebBridge } from './DrpyWebBridge';

// 桥的最小接口：DrpyDriver 仅依赖这两个方法（DrpyWebBridge 结构兼容即可赋值，单测注入 fake 覆盖默认）
export interface IDrpyBridge {
  ensureReady(cfg: SiteConfig): Promise<void>;
  call(method: string, args: string[], skey: string): Promise<string>;
}

// Record<string, Object> 索引取值后归一为 toStr/toInt 可接受的类型（与 CmsJsonApi 同款）
type JsonField = string | number | boolean | undefined;

function field(v: Record<string, Object>, key: string): JsonField {
  const raw = v[key];
  if (typeof raw === 'string') { return raw; }
  if (typeof raw === 'number') { return raw; }
  if (typeof raw === 'boolean') { return raw; }
  return undefined;
}

// 剥 HTML：先剥原始标签，再解码实体；解码可能让转义标签（&lt;img&gt;）复活，故再剥一次（与 CmsJsonApi 一致）
function stripHtml(s: string): string {
  return s.replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
    .replace(/<[^>]+>/g, '');
}

function pickMovie(v: Record<string, Object>): Movie {
  return {
    vodId: toStr(field(v, 'vod_id'), ''),
    name: toStr(field(v, 'vod_name'), ''),
    pic: toStr(field(v, 'vod_pic'), ''),
    remark: toStr(field(v, 'vod_remarks'), ''),
    typeName: toStr(field(v, 'type_name'), ''),
    score: toStr(field(v, 'vod_score'), '')
  };
}

export class DrpyDriver implements SiteDriver {
  private site: SiteConfig;
  private bridge: IDrpyBridge | null = null;

  // bridge 缺省时延迟取 DrpyWebBridge.instance（首次调用时才取，避免本地单测构造期触碰 Web 容器）；
  // 单测经可选第二参数注入 fake 覆盖默认
  constructor(site: SiteConfig, bridge?: IDrpyBridge) {
    this.site = site;
    this.bridge = bridge ?? null;
  }

  private getBridge(): IDrpyBridge {
    if (this.bridge === null) {
      this.bridge = DrpyWebBridge.instance as IDrpyBridge;
    }
    return this.bridge;
  }

  // 统一调用：每个接口方法前先 ensureReady（同站幂等），再 call 拿 JSON 字符串解析。
  // skey 显式随调用传递：桥是全 app 单例，多站并发时靠它路由到对应 Worker
  private async callJson(method: string, args: string[]): Promise<Record<string, Object>> {
    const bridge = this.getBridge();
    await bridge.ensureReady(this.site);
    const text = await bridge.call(method, args, this.site.key);
    return JSON.parse(text) as Record<string, Object>;
  }

  // 首页：{class:[{type_id,type_name}]} + homeVod 的 {list:[vod...]} → HomeContent。
  // drpy2 把推荐列表拆在独立的 homeVod 方法里，home 本身只回分类。
  async getHomeContent(): Promise<HomeContent> {
    const obj = await this.callJson('home', []);
    const classes = (obj['class'] ?? []) as Record<string, Object>[];
    const categories: Category[] = classes.map((c: Record<string, Object>): Category => {
      return { tid: toStr(field(c, 'type_id'), ''), name: toStr(field(c, 'type_name'), '') };
    });
    let list: Record<string, Object>[] = [];
    try {
      const hv = await this.callJson('homeVod', []);
      list = (hv['list'] ?? []) as Record<string, Object>[];
    } catch (e) { /* homeVod 失败不阻塞分类展示 */ }
    return { categories: categories, items: list.map(pickMovie) };
  }

  // 分类列表：{list:[{vod_id,...}],page,pagecount} → PageResult
  async categoryContent(tid: string, pg: number): Promise<PageResult> {
    const obj = await this.callJson('category', [tid, String(pg)]);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return {
      page: toInt(field(obj, 'page'), pg),
      pageCount: toInt(field(obj, 'pagecount'), 1),
      items: list.map(pickMovie)
    };
  }

  // 详情：{list:[vod...]}，vod_play_url 解析与 CmsJsonApi 同逻辑（$$$ 分线路 / # 分集 / 名称$地址 +
  // 相对路径按 site.api resolve），集名缺失时用序号兜底
  async detailContent(ids: string[]): Promise<MovieDetail> {
    const obj = await this.callJson('detail', [ids.join(',')]);
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

  // 播放解析：DRPY 特有流程（SiteDriver 接口无 play 且不得改动，播放层对 drpy 站按需调用本方法）；
  // 返回 {url,parse,header}，MVP 取 url 承载为 Episode.url（parse/header 留待播放层接入时扩展）
  async playContent(flag: string, id: string): Promise<Episode> {
    const obj = await this.callJson('play', [flag, id]);
    return { name: flag, url: toStr(field(obj, 'url'), ''), parse: toStr(field(obj, 'parse'), '0') };
  }

  // 搜索：{list:[vod...]} → PageResult（与 CMS 搜索语义一致，页码固定 1/1）
  async searchContent(key: string, quick: boolean): Promise<PageResult> {
    const obj = await this.callJson('search', [key, quick ? '1' : '0']);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return { page: 1, pageCount: 1, items: list.map(pickMovie) };
  }
}
