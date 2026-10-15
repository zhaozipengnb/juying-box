// AppState 单元测试：经 testFetchText 注入替代真网络，覆盖 loadFromUrl/initFromStore/switchSite
import { describe, it, expect } from '@ohos/hypium';
import { AppState } from '../main/ets/state/AppState';
import { ConfigStore, KVStore, serializeConfig } from '../main/ets/state/ConfigStore';
import { decodeConfigContent, TvboxConfig } from 'common';

// 内存 KVStore 假实现（模拟 preferences 行为）
class FakeKVStore implements KVStore {
  private map: Map<string, string> = new Map();
  getSync(k: string): string | undefined { return this.map.get(k); }
  putSync(k: string, v: string): void { this.map.set(k, v); }
  deleteSync(k: string): void { this.map.delete(k); }
}

// 最小 CMS 站点响应（CmsJsonApi 构造后首页会请求 ?ac=list）
const SITE_JSON = `{"class":[{"type_id":1,"type_name":"电影"}],"list":[]}`;

// 按内存 Map 响应的 FetchText 假实现（未命中抛 404）
function makeFakeFetch(responses: Map<string, string>): (url: string, headers?: Record<string, string>) => Promise<string> {
  return async (url: string, headers?: Record<string, string>): Promise<string> => {
    const hit = responses.get(url);
    if (hit === undefined) { throw new Error('404: ' + url); }
    return hit;
  };
}

const SUB_JSON = `{"sites":[{"key":"a","name":"站点A","type":1,"api":"https://a.example/api"},{"key":"b","name":"站点B","type":1,"api":"https://b.example/api"}]}`;

export default function appStateTest() {
  describe('appStateTest', () => {
    it('loadFromUrl_success_to_home_phase', 0, async () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', SUB_JSON);
      app.testFetchText = makeFakeFetch(responses);
      const ok = await app.loadFromUrl('https://sub.example/conf');
      expect(ok).assertTrue();
      expect(app.phase === 'home').assertTrue();
      expect(app.config !== null).assertTrue();
      expect((app.config as TvboxConfig).sites.length === 2).assertTrue();
      expect(app.currentSite?.key === 'a').assertTrue();
      expect(app.driver !== null).assertTrue();
    });
    it('loadFromUrl_bad_subscription_stays_config_with_err', 0, async () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', 'garbage');
      app.testFetchText = makeFakeFetch(responses);
      const ok = await app.loadFromUrl('https://sub.example/conf');
      expect(ok).assertFalse();
      expect(app.phase === 'config').assertTrue();
      expect(app.errMsg !== '').assertTrue();
    });
    it('initFromStore_with_saved_config_goes_home', 0, async () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://a.example/api?ac=list', SITE_JSON);
      app.testFetchText = makeFakeFetch(responses);
      const store = new ConfigStore(new FakeKVStore());
      const cfg = decodeConfigContent(SUB_JSON);
      store.save('https://sub.example/conf', serializeConfig('https://sub.example/conf', cfg));
      await app.initFromStore(store);
      expect(app.phase === 'home').assertTrue();
    });
    it('switchSite_rebuilds_driver', 0, async () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', SUB_JSON);
      app.testFetchText = makeFakeFetch(responses);
      await app.loadFromUrl('https://sub.example/conf');
      const before = app.driver;
      expect(app.switchSite('b')).assertTrue();
      // 实例比较先赋局部布尔变量再断言（hypium 匹配器适配）
      const changed = app.driver !== before;
      expect(changed).assertTrue();
      expect(app.currentSite?.key === 'b').assertTrue();
      expect(app.switchSite('nope')).assertFalse();
    });
    it('jar_site_routing_skipped_and_switch_rejected', 0, async () => {
      // 影视仓型订阅：首站是 csp_* JAR 类名源（不可当 URL 下载），后面跟一个 CMS 活站
      const jarSub = `{"sites":[`
        + `{"key":"j1","name":"JAR站","type":3,"api":"csp_Gz360"},`
        + `{"key":"c1","name":"CMS站","type":1,"api":"https://c.example/api"}]}`
        + ``;
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', jarSub);
      responses.set('https://c.example/api?ac=list', SITE_JSON);
      app.testFetchText = makeFakeFetch(responses);
      const ok = await app.loadFromUrl('https://sub.example/conf');
      expect(ok).assertTrue();
      expect(app.phase === 'home').assertTrue();
      // 首个受支持站点被选中（跳过 JAR 站），driver 为 CMS 而非尝试下载 csp_Gz360
      expect(app.currentSite?.key === 'c1').assertTrue();
      // 切到 JAR 站被拒绝（false），当前站点不变
      expect(app.switchSite('j1')).assertFalse();
      expect(app.currentSite?.key === 'c1').assertTrue();
    });
    it('all_jar_subscription_rejected_with_clear_error', 0, async () => {
      // 纯 JAR 型订阅：全部站点不支持 → 回 config 页并给出明确错误（而非 DNS 假错误）
      const jarOnly = `{"sites":[{"key":"j1","name":"JAR站","type":3,"api":"csp_X"},{"key":"j2","name":"JAR2","type":3,"api":"csp_Y"}]}`;
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', jarOnly);
      app.testFetchText = makeFakeFetch(responses);
      const ok = await app.loadFromUrl('https://sub.example/conf');
      expect(ok).assertFalse();
      expect(app.phase === 'config').assertTrue();
      expect(app.errMsg.includes('JAR')).assertTrue();
    });
  });
}
