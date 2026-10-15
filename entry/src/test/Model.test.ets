import { describe, it, expect } from '@ohos/hypium';
import { toInt, parseTvboxConfig, siteEngine, isSiteSupported, SiteConfig } from 'common';

// 便捷构造站点（仅填分类函数关注的字段，其余给默认值）
function mkSite(type: number, api: string): SiteConfig {
  return {
    key: 'k', name: 'n', type: type, api: api,
    searchable: 1, quickSearch: 1, filterable: 0,
    timeout: 10000, playerType: 0, jar: '', ext: '', header: {}
  };
}

export default function modelTest() {
  describe('ModelTest', () => {
    it('toInt_norm', 0, () => {
      expect(toInt('0', 9)).assertEqual(0);
      expect(toInt('2', 9)).assertEqual(2);
      expect(toInt(2, 9)).assertEqual(2);
      expect(toInt(undefined, 9)).assertEqual(9);
    });
    it('parseTvbox_norm', 0, () => {
      // ArkTS 严格模式禁用未类型化嵌套字面量，fixture 用 JSON 字符串构造
      const raw = JSON.parse('{'
        + '"spider":"http://a/b.jpg;md5;abc",'
        + '"sites":[{"key":"s1","name":"站1","type":"3","api":"csp_X","ext":{"a":"b"},"playerType":"2"}],'
        + '"lives":[{"name":"直播1","type":0,"url":"http://x.m3u"}],'
        + '"parses":[{"name":"p","type":0,"url":"http://p?url="}]'
        + '}') as Record<string, Object>;
      const cfg = parseTvboxConfig(raw);
      expect(cfg.spider).assertEqual('http://a/b.jpg;md5;abc');
      expect(cfg.sites.length).assertEqual(1);
      expect(cfg.sites[0].type).assertEqual(3);
      expect(cfg.sites[0].playerType).assertEqual(2);
      expect(cfg.sites[0].ext).assertEqual('{"a":"b"}');
      expect(cfg.lives[0].playerType).assertEqual(0);
      expect(Object.keys(cfg.sites[0].header).length).assertEqual(0);
    });
    it('siteEngine_classify', 0, () => {
      // type 1 → CMS JSON
      expect(siteEngine(mkSite(1, 'https://a.example/api.php')) === 'cms').assertTrue();
      // type 3 + http(s) URL → JS 插件（含带 query / 大写协议）
      expect(siteEngine(mkSite(3, 'https://a.example/drpy/x.js')) === 'js').assertTrue();
      expect(siteEngine(mkSite(3, 'http://a.example/x.js?token=1')) === 'js').assertTrue();
      expect(siteEngine(mkSite(3, 'HTTPS://a.example/X.JS')) === 'js').assertTrue();
      // type 3 + 非 URL（csp_* 类名 / 空串 / 裸词）→ JAR spider
      expect(siteEngine(mkSite(3, 'csp_Gz360')) === 'jar').assertTrue();
      expect(siteEngine(mkSite(3, 'csp_Douban')) === 'jar').assertTrue();
      expect(siteEngine(mkSite(3, '')) === 'jar').assertTrue();
      // 其余类型 → unknown
      expect(siteEngine(mkSite(0, 'https://a.example/x')) === 'unknown').assertTrue();
      expect(siteEngine(mkSite(4, 'csp_X')) === 'unknown').assertTrue();
      // 支持面：cms + js，jar / unknown 不支持
      expect(isSiteSupported(mkSite(1, 'https://a.example/api.php'))).assertTrue();
      expect(isSiteSupported(mkSite(3, 'https://a.example/x.js'))).assertTrue();
      expect(isSiteSupported(mkSite(3, 'csp_Gz360'))).assertFalse();
      expect(isSiteSupported(mkSite(4, 'x'))).assertFalse();
    });
  });
}
