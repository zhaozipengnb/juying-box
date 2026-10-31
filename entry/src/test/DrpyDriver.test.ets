// DrpyDriver 单元测试：注入 fake bridge（固定 JSON 返回），断言 DRPY 返回 → common 模型解析正确性；
// 附 AppState.buildDriver 类型路由用例（type 3 → DrpyDriver、type 1 → CmsJsonApi）
import { describe, it, expect } from '@ohos/hypium';
import { CmsJsonApi, XmlCmsDriver, SiteConfig } from 'common';
import { AppState } from '../main/ets/state/AppState';
import { DrpyDriver, IDrpyBridge } from '../main/ets/spider/DrpyDriver';

const SITE: SiteConfig = {
  key: 'drpy', name: 'DRPY测试站', type: 3, api: 'http://demo/drpy.js',
  searchable: 1, quickSearch: 1, filterable: 0, timeout: 10000, playerType: 0,
  jar: '', ext: '', header: {}
};

// fake bridge：按方法名返回固定 JSON，记录调用轨迹（ensureReady 次数 / 最近一次 call 参数）
class FakeBridge implements IDrpyBridge {
  readyCount: number = 0;
  lastMethod: string = '';
  lastArgs: string[] = [];
  private responses: Record<string, string>;

  constructor(responses: Record<string, string>) {
    this.responses = responses;
  }

  async ensureReady(cfg: SiteConfig): Promise<void> {
    this.readyCount++;
  }

  async call(method: string, args: string[], skey: string): Promise<string> {
    this.lastMethod = method;
    this.lastArgs = args;
    return this.responses[method] ?? '{}';
  }
}

// fixture：合成 drpy 返回（非真实站点数据）
const HOME_JSON = '{"class":[{"type_id":1,"type_name":"电影"},{"type_id":2,"type_name":"剧集"}],"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集","type_name":"电影"}]}';
const CATEGORY_JSON = '{"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"},{"vod_id":12,"vod_name":"片B","vod_pic":"","vod_remarks":"HD"}],"page":2,"pagecount":5}';
const DETAIL_JSON = '{"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集","type_name":"电影","vod_year":"2024","vod_actor":"甲,乙","vod_director":"丙","vod_content":"简介&lt;img src=x&gt;","vod_play_from":"线路1$$$线路2","vod_play_url":"第01集$http://v/1.m3u8#第02集$/play/2.m3u8$$$EP1$http://v/b.mp4"}]}';
const PLAY_JSON = '{"url":"http://v/1.m3u8","parse":0,"header":{"User-Agent":"okhttp"}}';
const SEARCH_JSON = '{"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"}]}';

// 订阅 fixture：混合站点（type 3 打头）与纯 drpy 站点
const SUB_MIXED = '{"sites":[{"key":"d","name":"DRPY站","type":3,"api":"http://demo/drpy.js"},{"key":"c","name":"CMS站","type":1,"api":"https://c.example/api"}]}';
const SUB_PURE_DRPY = '{"sites":[{"key":"d1","name":"DRPY1","type":3,"api":"http://x/1.js"},{"key":"d2","name":"DRPY2","type":3,"api":"http://x/2.js"}]}';
// type 4 已是 AppYs 引擎（受支持）；真正不支持的是 type 5 等
const SUB_UNSUPPORTED = '{"sites":[{"key":"z","name":"Z","type":5,"api":"http://x/z"}]}';
// type 0 XML 采集站路由
const SUB_XML = '{"sites":[{"key":"x1","name":"XML站","type":0,"api":"https://x.example/api.php/provide/vod/at/xml/"}]}';

// 经 testFetchText 注入订阅文本走 loadFromUrl，触发 buildDriver 路由
async function loadSub(subJson: string): Promise<AppState> {
  const app = new AppState();
  const responses: Map<string, string> = new Map();
  responses.set('https://sub.example/conf', subJson);
  app.testFetchText = async (url: string, headers?: Record<string, string>): Promise<string> => {
    return responses.get(url) ?? '';
  };
  await app.loadFromUrl('https://sub.example/conf');
  return app;
}

export default function drpyDriverTest() {
  describe('DrpyDriverTest', () => {
    it('home_content', 0, async () => {
      // drpy2 拆分：home 回分类，homeVod 回推荐列表
      const bridge = new FakeBridge({
        'home': HOME_JSON,
        'homeVod': '{"list":[{"vod_id":"22","vod_name":"片B","vod_pic":"http://p/b.jpg","vod_remarks":"蓝光"}]}'
      });
      const driver = new DrpyDriver(SITE, bridge);
      const home = await driver.getHomeContent();
      expect(home.categories.length).assertEqual(2);
      expect(home.categories[0].tid).assertEqual('1');
      expect(home.categories[1].name).assertEqual('剧集');
      expect(home.items.length).assertEqual(1);
      expect(home.items[0].vodId).assertEqual('22');
      expect(home.items[0].name).assertEqual('片B');
      expect(bridge.readyCount).assertEqual(2); // home + homeVod 各一次 ensureReady（同 skey 幂等）
      expect(bridge.lastMethod).assertEqual('homeVod');
    });
    it('category_page', 0, async () => {
      const bridge = new FakeBridge({ 'category': CATEGORY_JSON });
      const driver = new DrpyDriver(SITE, bridge);
      const page = await driver.categoryContent('1', 2);
      expect(page.page).assertEqual(2);
      expect(page.pageCount).assertEqual(5);
      expect(page.items.length).assertEqual(2);
      expect(page.items[1].remark).assertEqual('HD');
      expect(bridge.lastArgs.length).assertEqual(2);
      expect(bridge.lastArgs[0]).assertEqual('1');
      expect(bridge.lastArgs[1]).assertEqual('2'); // pg 转字符串传参
    });
    it('detail_lines_episodes', 0, async () => {
      const bridge = new FakeBridge({ 'detail': DETAIL_JSON });
      const driver = new DrpyDriver(SITE, bridge);
      const d = await driver.detailContent(['11']);
      expect(d.lines.length).assertEqual(2);
      expect(d.lines[0].from).assertEqual('线路1');
      expect(d.lines[0].episodes.length).assertEqual(2);
      expect(d.lines[0].episodes[0].url).assertEqual('http://v/1.m3u8');
      // 相对路径按 site.api origin resolve（同 CmsJsonApi.resolvePlayUrl 语义）
      expect(d.lines[0].episodes[1].url).assertEqual('http://demo/play/2.m3u8');
      expect(d.lines[1].from).assertEqual('线路2');
      expect(d.lines[1].episodes[0].name).assertEqual('EP1');
      expect(d.desc.indexOf('<img') < 0).assertTrue(); // 简介需剥 HTML 标签
      expect(d.year).assertEqual('2024');
      expect(bridge.lastArgs[0]).assertEqual('11');
    });
    it('play_episode_url', 0, async () => {
      const bridge = new FakeBridge({ 'play': PLAY_JSON });
      const driver = new DrpyDriver(SITE, bridge);
      const ep = await driver.playContent('m3u8', '11/1.m3u8');
      expect(ep.url).assertEqual('http://v/1.m3u8'); // 取返回 JSON 的 url 字段
      expect(bridge.lastMethod).assertEqual('play');
      expect(bridge.lastArgs.length).assertEqual(2);
      expect(bridge.lastArgs[0]).assertEqual('m3u8');
      expect(bridge.lastArgs[1]).assertEqual('11/1.m3u8');
    });
    it('search', 0, async () => {
      const bridge = new FakeBridge({ 'search': SEARCH_JSON });
      const driver = new DrpyDriver(SITE, bridge);
      const r = await driver.searchContent('片A', false);
      expect(r.items.length).assertEqual(1);
      expect(r.items[0].name).assertEqual('片A');
      expect(r.page).assertEqual(1);
      expect(bridge.lastArgs.length).assertEqual(2);
      expect(bridge.lastArgs[0]).assertEqual('片A');
      expect(bridge.lastArgs[1]).assertEqual('0'); // quick=false → '0'
    });
    it('ensure_ready_before_every_method', 0, async () => {
      const bridge = new FakeBridge({ 'home': HOME_JSON, 'homeVod': '{"list":[]}', 'search': SEARCH_JSON });
      const driver = new DrpyDriver(SITE, bridge);
      await driver.getHomeContent();
      await driver.searchContent('x', true);
      expect(bridge.readyCount).assertEqual(3); // home+homeVod+search 各一次（同 skey 幂等累加）
      expect(bridge.lastArgs[1]).assertEqual('1'); // quick=true → '1'
    });
    it('app_state_route_type3_to_drpy_driver', 0, async () => {
      const app = await loadSub(SUB_MIXED);
      expect(app.phase === 'home').assertTrue();
      const isDrpy = app.driver instanceof DrpyDriver;
      expect(isDrpy).assertTrue(); // sites[0] 为 type 3 → DrpyDriver
    });
    it('app_state_route_type1_to_cms_driver', 0, async () => {
      const app = await loadSub(SUB_MIXED);
      expect(app.switchSite('c')).assertTrue();
      const isCms = app.driver instanceof CmsJsonApi;
      expect(isCms).assertTrue(); // type 1 → CmsJsonApi
      expect(app.currentSite?.key === 'c').assertTrue();
    });
    it('app_state_pure_drpy_subscription_accepted', 0, async () => {
      const app = await loadSub(SUB_PURE_DRPY);
      expect(app.phase === 'home').assertTrue(); // 纯 drpy 订阅不再被"无 CMS 站点"门槛拒绝
      const isDrpy = app.driver instanceof DrpyDriver;
      expect(isDrpy).assertTrue();
    });
    it('app_state_unsupported_types_rejected', 0, async () => {
      const app = await loadSub(SUB_UNSUPPORTED);
      expect(app.phase === 'home').assertFalse(); // 全部为不支持类型仍拒绝（失败留在发起页，不进 home）
      expect(app.errMsg !== '').assertTrue();
    });
    it('app_state_route_type0_to_xml_driver', 0, async () => {
      const app = await loadSub(SUB_XML);
      expect(app.phase === 'home').assertTrue();
      const isXml = app.driver instanceof XmlCmsDriver;
      expect(isXml).assertTrue(); // type 0 → XmlCmsDriver
    });
  });
}
