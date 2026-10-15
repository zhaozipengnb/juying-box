// XmlCmsDriver 单测：fixture 取自量子资源真实响应（值有改写），覆盖分类/首页/列表/详情/搜索。
import { describe, it, expect } from '@ohos/hypium';
import { XmlCmsDriver, SiteConfig } from 'common';

// 真实形态样本：值带 CDATA、属性带分页、播放串走 dd flag + $/# 约定
const XML_LIST = '<?xml version="1.0" encoding="utf-8"?><rss version="5.1">'
  + '<class><ty id="1">电影片</ty><ty id="2">连续剧</ty></class>'
  + '<list page="1" pagecount="7960" pagesize="20" recordcount="159183">'
  + '<video><last>2026-10-16 00:33:13</last><id>159229</id><tid>30</tid><name><![CDATA[伤痕累累的圣女的复仇第二季]]></name><type>日韩动漫</type><dt>lzm3u8</dt><note><![CDATA[更新至第03集]]></note></video>'
  + '<video><last>2026-10-16 00:11:13</last><id>151532</id><tid>21</tid><name><![CDATA[针线缘]]></name><type>台湾剧</type><dt>lzm3u8</dt><note><![CDATA[更新至第48集]]></note></video>'
  + '</list></rss>';

const XML_HOME = '<?xml version="1.0" encoding="utf-8"?><rss version="5.1">'
  + '<list page="1" pagecount="7960" pagesize="20" recordcount="159183">'
  + '<video><id>159229</id><tid>30</tid><name><![CDATA[伤痕累累的圣女的复仇第二季]]></name><type>日韩动漫</type>'
  + '<pic>https://img.example/p1.webp</pic><year>2026</year><note><![CDATA[更新至第03集]]></note>'
  + '<dl><dd flag="lzm3u8"><![CDATA[第01集$https://v.example/1/index.m3u8#第02集$https://v.example/2/index.m3u8]]></dd></dl>'
  + '</video></list></rss>';

const XML_DETAIL = '<?xml version="1.0" encoding="utf-8"?><rss version="5.1">'
  + '<list page="1" pagecount="1" pagesize="20" recordcount="1">'
  + '<video><id>111482</id><tid>1</tid><name><![CDATA[阿龙2025]]></name><type>电影片</type>'
  + '<pic>https://img.example/d1.jpg</pic><year>2025</year><note><![CDATA[HD]]></note>'
  + '<actor><![CDATA[郑中基,傅舜盈]]></actor><director><![CDATA[郑中基]]></director>'
  + '<dl><dd flag="lzm3u8"><![CDATA[国语中字$https://v.example/d/index.m3u8]]></dd>'
  + '<dd flag="down"><![CDATA[第01集$/down/path/a.mp4]]></dd></dl>'
  + '<des><![CDATA[<p>剧情简介正文</p>]]></des>'
  + '</video></list></rss>';

const XML_SEARCH = '<?xml version="1.0" encoding="utf-8"?><rss version="5.1">'
  + '<list page="1" pagecount="3" pagesize="20" recordcount="55">'
  + '<video><id>90001</id><tid>1</tid><name><![CDATA[搜索命中A]]></name><type>电影片</type><note><![CDATA[HD]]></note></video>'
  + '</list></rss>';

const SITE: SiteConfig = {
  key: 'lz', name: '量子', type: 0,
  api: 'https://cj.example/api.php/provide/vod/from/lzm3u8/at/xml/?ac=list',
  searchable: 1, quickSearch: 1, filterable: 0,
  timeout: 15000, playerType: 0, jar: '', ext: '', header: {}
};

function makeFetch(responses: Map<string, string>): (url: string, headers?: Record<string, string>) => Promise<string> {
  return (url: string, headers?: Record<string, string>): Promise<string> => {
    const hit = responses.get(url);
    return Promise.resolve(hit === undefined ? '<rss><list page="1" pagecount="1"></list></rss>' : hit);
  };
}

export default function xmlCmsDriverTest() {
  describe('XmlCmsDriverTest', () => {
    it('home_content', 0, async () => {
      const responses: Map<string, string> = new Map();
      // api 自带 query（?ac=list）必须被剥掉再拼参数，避免双 query
      responses.set('https://cj.example/api.php/provide/vod/from/lzm3u8/at/xml/?ac=list', XML_LIST);
      responses.set('https://cj.example/api.php/provide/vod/from/lzm3u8/at/xml/?ac=videolist&pg=1', XML_HOME);
      const d = new XmlCmsDriver(SITE, makeFetch(responses));
      const home = await d.getHomeContent();
      expect(home.categories.length).assertEqual(2);
      expect(home.categories[0].tid).assertEqual('1');
      expect(home.categories[1].name).assertEqual('连续剧');
      expect(home.items.length).assertEqual(1);
      expect(home.items[0].vodId).assertEqual('159229');
      expect(home.items[0].name).assertEqual('伤痕累累的圣女的复仇第二季');
      expect(home.items[0].pic).assertEqual('https://img.example/p1.webp');
      expect(home.items[0].remark).assertEqual('更新至第03集');
    });
    it('category_page', 0, async () => {
      const responses: Map<string, string> = new Map();
      let requested = '';
      const rec: (url: string, headers?: Record<string, string>) => Promise<string> = (url: string): Promise<string> => {
        requested = url;
        return Promise.resolve(responses.get(url) ?? XML_LIST);
      };
      const d = new XmlCmsDriver(SITE, rec);
      const pg = await d.categoryContent('30', 2);
      expect(requested).assertEqual('https://cj.example/api.php/provide/vod/from/lzm3u8/at/xml/?ac=videolist&t=30&pg=2');
      expect(pg.page).assertEqual(1);
      expect(pg.pageCount).assertEqual(7960);
      expect(pg.items.length).assertEqual(2);
      expect(pg.items[1].vodId).assertEqual('151532');
    });
    it('detail_lines_episodes', 0, async () => {
      const responses: Map<string, string> = new Map();
      responses.set('https://cj.example/api.php/provide/vod/from/lzm3u8/at/xml/?ac=videolist&ids=111482', XML_DETAIL);
      const d = new XmlCmsDriver(SITE, makeFetch(responses));
      const det = await d.detailContent(['111482']);
      expect(det.movie.vodId).assertEqual('111482');
      expect(det.movie.name).assertEqual('阿龙2025');
      expect(det.year).assertEqual('2025');
      expect(det.actor).assertEqual('郑中基,傅舜盈');
      expect(det.desc).assertEqual('剧情简介正文');
      expect(det.lines.length).assertEqual(2);
      expect(det.lines[0].from).assertEqual('lzm3u8');
      expect(det.lines[0].episodes[0].name).assertEqual('国语中字');
      expect(det.lines[0].episodes[0].url).assertEqual('https://v.example/d/index.m3u8');
      // 相对地址按站点 origin 补全（resolvePlayUrl：/ 开头拼 protocol//host）
      expect(det.lines[1].from).assertEqual('down');
      expect(det.lines[1].episodes[0].url).assertEqual('https://cj.example/down/path/a.mp4');
    });
    it('search', 0, async () => {
      const responses: Map<string, string> = new Map();
      responses.set('https://cj.example/api.php/provide/vod/from/lzm3u8/at/xml/?ac=videolist&wd=' + encodeURIComponent('爱'), XML_SEARCH);
      const d = new XmlCmsDriver(SITE, makeFetch(responses));
      const pg = await d.searchContent('爱', false);
      expect(pg.pageCount).assertEqual(3);
      expect(pg.items[0].name).assertEqual('搜索命中A');
    });
  });
}
