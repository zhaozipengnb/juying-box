/**
 * XmlCmsDriver：MacCMS XML 采集协议引擎（站点 type 0，api 形如 …/api.php/provide/vod/at/xml）
 * 协议（响应为机器生成的规整 XML，值可包 CDATA）：
 *   分类+首页 GET {api}?ac=list                  → <class><ty id="1">电影</ty>…</class><list page pagecount><video>…
 *   首页条目  GET {api}?ac=videolist&pg=1         → 完整字段（含 pic/dl），20 条/页
 *   列表      GET {api}?ac=videolist&t={tid}&pg={pg}
 *   详情      GET {api}?ac=videolist&ids={id}
 *   搜索      GET {api}?ac=videolist&wd={key}
 *   播放串    <dl><dd flag="线路"><![CDATA[名称$地址#名称$地址]]></dd></dl>
 * api 可能自带 query（如 …/at/xml/?ac=list），拼参数前剥掉；尾 '/' 有无皆可。
 */
import { SiteConfig } from '../model/TvboxModels';
import { HomeContent, PageResult, MovieDetail, Movie, Category, Episode, PlayLine } from '../model/VideoModels';
import { FetchText, SiteDriver } from './SiteDriver';
import { CmsJsonApi } from './CmsJsonApi';

// list 分页属性（ArkTS 不允许对象字面量作类型，故用具名接口）
export interface XmlPageInfo {
  page: number;
  pageCount: number;
}

// ---------- 极简 XML 取值（MacCMS 输出为扁平机器格式，无嵌套同名标签，按下标扫描足够） ----------

// 首个 <tag …> 与 </tag> 之间的原文（不含标签）；不存在返回 ''
function firstTag(xml: string, tag: string): string {
  const open = xml.indexOf('<' + tag);
  if (open < 0) { return ''; }
  const gt = xml.indexOf('>', open);
  if (gt < 0) { return ''; }
  const close = xml.indexOf('</' + tag + '>', gt + 1);
  if (close < 0) { return ''; }
  return xml.substring(gt + 1, close);
}

// 所有 <tag …>…</tag> 外层块（含标签本身）；用于 <video>/<dd> 这类重复节点
function tagBlocks(xml: string, tag: string): string[] {
  const out: string[] = [];
  const openMark = '<' + tag;
  const closeMark = '</' + tag + '>';
  let i = xml.indexOf(openMark);
  while (i >= 0) {
    const gt = xml.indexOf('>', i);
    const close = gt < 0 ? -1 : xml.indexOf(closeMark, gt + 1);
    if (gt < 0 || close < 0) { break; }
    out.push(xml.substring(i, close + closeMark.length));
    i = xml.indexOf(openMark, close + closeMark.length);
  }
  return out;
}

// 剥一层 CDATA 包装；无包装原样返回
function unwrapCdata(s: string): string {
  const t = s.trim();
  if (t.startsWith('<![CDATA[') && t.endsWith(']]>')) {
    return t.substring('<![CDATA['.length, t.length - ']]>'.length);
  }
  return t;
}

// 标签文本值 = 原文剥 CDATA（HTML 实体由 stripHtml 链路统一处理）
function tagText(xml: string, tag: string): string {
  return unwrapCdata(firstTag(xml, tag));
}

// 开标签里的属性值（如 <list page="1" pagecount="9"> 取 page）
function tagAttr(block: string, attr: string): string {
  const m = block.match(new RegExp(attr + '="([^"]*)"'));
  return m === null ? '' : m[1];
}

function stripTags(s: string): string {
  return s.replace(/<[^>]+>/g, '');
}

function decodeEntities(s: string): string {
  return s.replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').replace(/&quot;/g, '"');
}

// 剥 HTML：先剥原始标签，再解码实体；解码可能让转义标签复活，故再剥一次（与 CmsJsonApi 一致）
function stripHtml(s: string): string {
  return stripTags(decodeEntities(stripTags(s)));
}

// `名称$地址#名称$地址` → Episode[]；无 $ 的段整段为地址，集名用 第N集
function parseEpisodes(raw: string): Episode[] {
  const out: Episode[] = [];
  const parts = raw.split('#');
  for (let i = 0; i < parts.length; i++) {
    const seg = parts[i].trim();
    if (seg === '') { continue; }
    const dollar = seg.indexOf('$');
    if (dollar > 0) {
      out.push({ name: seg.substring(0, dollar), url: seg.substring(dollar + 1) });
    } else {
      out.push({ name: '第' + (i + 1) + '集', url: seg });
    }
  }
  return out;
}

function pickMovie(v: string): Movie {
  return {
    vodId: tagText(v, 'id'),
    name: tagText(v, 'name'),
    pic: tagText(v, 'pic'),
    remark: tagText(v, 'note'),
    typeName: tagText(v, 'type')
  };
}

export class XmlCmsDriver implements SiteDriver {
  private site: SiteConfig;
  private fetchText: FetchText;

  constructor(site: SiteConfig, fetchText: FetchText) {
    this.site = site;
    this.fetchText = fetchText;
  }

  // api 可能自带 query（天涯源 …/at/xml/?ac=list），剥掉再拼参数
  private base(): string {
    return this.site.api.split('?')[0];
  }

  private async getXml(path: string): Promise<string> {
    return this.fetchText(`${this.base()}${path}`, this.site.header);
  }

  // list 分页属性：<list page="1" pagecount="7960" …>
  private static pageInfo(xml: string): XmlPageInfo {
    const open = xml.indexOf('<list');
    const gt = open < 0 ? -1 : xml.indexOf('>', open);
    const head = open < 0 || gt < 0 ? '' : xml.substring(open, gt + 1);
    const page = parseInt(tagAttr(head, 'page'), 10);
    const pageCount = parseInt(tagAttr(head, 'pagecount'), 10);
    return { page: isNaN(page) ? 1 : page, pageCount: isNaN(pageCount) ? 1 : pageCount };
  }

  async getHomeContent(): Promise<HomeContent> {
    // 分类取 ac=list；首页条目用 ac=videolist&pg=1（含 pic/dl 完整字段）
    const pair = await Promise.all([
      this.getXml('?ac=list'), this.getXml('?ac=videolist&pg=1')
    ]);
    const clsXml = pair[0];
    const listXml = pair[1];
    const categories: Category[] = [];
    const classXml = firstTag(clsXml, 'class');
    for (const ty of tagBlocks(classXml, 'ty')) {
      const id = tagAttr(ty, 'id');
      const name = unwrapCdata(ty.substring(ty.indexOf('>') + 1, ty.lastIndexOf('</ty>')));
      if (id !== '' && name !== '') { categories.push({ tid: id, name: name }); }
    }
    const items: Movie[] = tagBlocks(listXml, 'video').map((v: string): Movie => pickMovie(v));
    return { categories: categories, items: items };
  }

  async categoryContent(tid: string, pg: number): Promise<PageResult> {
    const xml = await this.getXml(`?ac=videolist&t=${tid}&pg=${pg}`);
    const info = XmlCmsDriver.pageInfo(xml);
    const items: Movie[] = tagBlocks(xml, 'video').map((v: string): Movie => pickMovie(v));
    return { page: info.page, pageCount: info.pageCount, items: items };
  }

  async detailContent(ids: string[]): Promise<MovieDetail> {
    const xml = await this.getXml(`?ac=videolist&ids=${ids.join(',')}`);
    const block = tagBlocks(xml, 'video')[0];
    if (block === undefined) { throw new Error('详情为空'); }
    const movie = pickMovie(block);
    const lines: PlayLine[] = [];
    const dl = firstTag(block, 'dl');
    for (const dd of tagBlocks(dl, 'dd')) {
      const from = tagAttr(dd, 'flag');
      const eps = parseEpisodes(tagText(dd, 'dd'));
      const resolved: Episode[] = eps.map((e: Episode): Episode => {
        return { name: e.name, url: CmsJsonApi.resolvePlayUrl(this.site, e.url) };
      });
      if (resolved.length > 0) { lines.push({ from: from === '' ? '默认' : from, episodes: resolved }); }
    }
    return {
      movie: movie,
      desc: stripHtml(tagText(block, 'des')),
      year: tagText(block, 'year'),
      actor: stripHtml(tagText(block, 'actor')),
      director: stripHtml(tagText(block, 'director')),
      lines: lines
    };
  }

  async searchContent(key: string, quick: boolean): Promise<PageResult> {
    const xml = await this.getXml(`?ac=videolist&wd=${encodeURIComponent(key)}`);
    const info = XmlCmsDriver.pageInfo(xml);
    const items: Movie[] = tagBlocks(xml, 'video').map((v: string): Movie => pickMovie(v));
    return { page: info.page, pageCount: info.pageCount, items: items };
  }
}
