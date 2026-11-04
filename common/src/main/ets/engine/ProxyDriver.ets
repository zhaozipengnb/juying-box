/**
 * ProxyDriver：将 csp_* JAR 爬虫请求转发到远程代理服务器执行。
 * 代理服务器需加载 外部 JAR 并执行 Java 爬虫类，返回标准 JSON。
 * API 格式：GET {proxyUrl}/api?site={key}&action={home|category|search|detail}&...
 */
import { SiteDriver, FetchText } from './SiteDriver';
import { HomeContent, PageResult, MovieDetail, Movie, Category, PlayLine, Episode } from '../model/VideoModels';
import { SiteConfig } from '../model/AggModels';

export class ProxyDriver implements SiteDriver {
  private site: SiteConfig;
  private fetch: FetchText;
  private proxyUrl: string;

  constructor(site: SiteConfig, fetchText: FetchText, proxyUrl: string) {
    this.site = site;
    this.fetch = fetchText;
    this.proxyUrl = proxyUrl.replace(/\/+$/, '');
  }

  /** 统一代理请求入口：网络异常时给出可读提示而非裸 timeout */
  private async callProxy(url: string): Promise<Record<string, Object>> {
    let json: string;
    try {
      json = await this.fetch(url, { 'User-Agent': 'okhttp/4.9.3' });
    } catch (e) {
      let raw: string;
      if (e instanceof Error) { raw = e.message; }
      else {
        try { raw = JSON.stringify(e); } catch (_) { raw = String(e); }
      }
      throw new Error(`代理服务器无法连接（${raw}），请在设置中检查JAR代理地址`);
    }
    try {
      return JSON.parse(json) as Record<string, Object>;
    } catch (e) {
      throw new Error(`代理服务器返回了非JSON数据，请检查代理服务是否正常运行`);
    }
  }

  async getHomeContent(): Promise<HomeContent> {
    const url = `${this.proxyUrl}/api?site=${encodeURIComponent(this.site.key)}&action=home`;
    const obj = await this.callProxy(url);
    return {
      categories: this.parseCategories(obj['categories']),
      items: this.parseMovies(obj['list'])
    };
  }

  async categoryContent(tid: string, pg: number): Promise<PageResult> {
    const url = `${this.proxyUrl}/api?site=${encodeURIComponent(this.site.key)}&action=category&tid=${encodeURIComponent(tid)}&page=${pg}`;
    const obj = await this.callProxy(url);
    return {
      page: pg,
      pageCount: this.toNum(obj['pagecount'], 1),
      items: this.parseMovies(obj['list'])
    };
  }

  async searchContent(key: string, _quick: boolean): Promise<PageResult> {
    const url = `${this.proxyUrl}/api?site=${encodeURIComponent(this.site.key)}&action=search&wd=${encodeURIComponent(key)}&page=1`;
    const obj = await this.callProxy(url);
    return {
      page: 1,
      pageCount: this.toNum(obj['pagecount'], 1),
      items: this.parseMovies(obj['list'])
    };
  }

  async detailContent(ids: string[]): Promise<MovieDetail> {
    const url = `${this.proxyUrl}/api?site=${encodeURIComponent(this.site.key)}&action=detail&ids=${encodeURIComponent(ids.join(','))}`;
    const obj = await this.callProxy(url);
    const list = this.parseMovies(obj['list']);
    const movie: Movie = list.length > 0 ? list[0] : { vodId: ids[0], name: '', pic: '', remark: '', typeName: '' };
    return {
      movie: movie,
      desc: this.toStr(obj['desc']),
      year: this.toStr(obj['year']),
      actor: this.toStr(obj['actor']),
      director: this.toStr(obj['director']),
      lines: this.parseLines(obj['plays'])
    };
  }

  private parseCategories(raw: Object): Category[] {
    if (!Array.isArray(raw)) { return []; }
    return (raw as Object[]).map((item): Category => {
      const o = item as Record<string, Object>;
      const cat: Category = { tid: this.toStr(o['tid'] ?? o['id']), name: this.toStr(o['name'] ?? o['title']) };
      return cat;
    }).filter(c => c.tid !== '' && c.name !== '');
  }

  private parseMovies(raw: Object): Movie[] {
    if (!Array.isArray(raw)) { return []; }
    return (raw as Object[]).map((item): Movie => {
      const o = item as Record<string, Object>;
      const m: Movie = {
        vodId: this.toStr(o['vod_id'] ?? o['id']),
        name: this.toStr(o['vod_name'] ?? o['title'] ?? o['name']),
        pic: this.toStr(o['vod_pic'] ?? o['pic']),
        remark: this.toStr(o['vod_remarks'] ?? o['remark'] ?? o['note']),
        typeName: this.toStr(o['type_name'] ?? o['typeName'] ?? o['cat'])
      };
      return m;
    }).filter(m => m.vodId !== '' && m.name !== '');
  }

  private parseLines(raw: Object): PlayLine[] {
    if (!Array.isArray(raw)) { return []; }
    return (raw as Object[]).map((item): PlayLine => {
      const o = item as Record<string, Object>;
      const eps = this.parseEpisodes(o['episodes'] ?? o['list']);
      const line: PlayLine = { from: this.toStr(o['from'] ?? o['flag'] ?? o['title']), episodes: eps };
      return line;
    }).filter(l => l.episodes.length > 0);
  }

  private parseEpisodes(raw: Object): Episode[] {
    if (!Array.isArray(raw)) { return []; }
    return (raw as Object[]).map((item): Episode => {
      const o = item as Record<string, Object>;
      const ep: Episode = { name: this.toStr(o['name'] ?? o['title']), url: this.toStr(o['url'] ?? o['playUrl']) };
      return ep;
    }).filter(e => e.url !== '');
  }

  private toStr(v: Object | undefined): string {
    return v === undefined || v === null ? '' : String(v);
  }

  private toNum(v: Object | undefined, def: number): number {
    const n = parseInt(this.toStr(v), 10);
    return isNaN(n) ? def : n;
  }
}
