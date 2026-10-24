import { describe, it, expect } from '@ohos/hypium';
import { toInt, parseTvboxConfig, siteEngine, isSiteSupported, resolveUrl, resolveSiteUrls,
  SiteConfig, TvboxConfig, tryConvertCspToCms } from 'common';

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
      // type 3 + builtin:// → 包内 drpy 源
      expect(siteEngine(mkSite(3, 'builtin://drpy2.min.js')) === 'js').assertTrue();
      expect(isSiteSupported(mkSite(3, 'builtin://drpy2.min.js'))).assertTrue();
      // type 3 + 非 URL（csp_* 类名 / 空串 / 裸词）→ JAR spider
      expect(siteEngine(mkSite(3, 'csp_Gz360')) === 'proxy').assertTrue();
      expect(siteEngine(mkSite(3, 'csp_Douban')) === 'proxy').assertTrue();
      expect(siteEngine(mkSite(3, '')) === 'proxy').assertTrue();
      // type 0 → XML 采集（TVBox 约定）；type 4 → AppYs；其余类型 → unknown
      expect(siteEngine(mkSite(0, 'https://a.example/api.php/provide/vod/at/xml')) === 'xml').assertTrue();
      expect(isSiteSupported(mkSite(0, 'https://a.example/api.php/provide/vod/at/xml'))).assertTrue();
      expect(siteEngine(mkSite(4, 'https://a.example/api')) === 'appys').assertTrue();
      expect(isSiteSupported(mkSite(4, 'https://a.example/api'))).assertTrue();
      expect(siteEngine(mkSite(5, 'csp_X')) === 'unknown').assertTrue();
      // 支持面：cms + xml + js + appys，jar / unknown 不支持
      expect(isSiteSupported(mkSite(1, 'https://a.example/api.php'))).assertTrue();
      expect(isSiteSupported(mkSite(3, 'https://a.example/x.js'))).assertTrue();
      expect(isSiteSupported(mkSite(3, 'csp_Gz360'))).assertTrue();   // JAR 代理引擎（需代理服务器）
      expect(isSiteSupported(mkSite(5, 'x'))).assertFalse();
    });
    it('resolveUrl_basics', 0, () => {
      // 绝对引用原样（含大小写协议、非 http scheme）
      expect(resolveUrl('https://a.com/x/c.json', 'https://b.com/y.js')).assertEqual('https://b.com/y.js');
      expect(resolveUrl('https://a.com/x/c.json', 'HTTP://b.com/y.js')).assertEqual('HTTP://b.com/y.js');
      // 协议相对 / 根相对
      expect(resolveUrl('https://a.com/x/c.json', '//cdn.a.com/l.js')).assertEqual('https://cdn.a.com/l.js');
      expect(resolveUrl('https://a.com/x/c.json', '/lib/l.js')).assertEqual('https://a.com/lib/l.js');
      // 文件级 base：目录相对
      expect(resolveUrl('https://a.com/x/c.json', './drpy_libs/drpy2.min.js'))
        .assertEqual('https://a.com/x/drpy_libs/drpy2.min.js');
      expect(resolveUrl('https://a.com/x/c.json', '../js/n.js')).assertEqual('https://a.com/js/n.js');
      // 目录级 base（尾 /）：./ 不产生重复段
      expect(resolveUrl('https://a.com/x/', './l.js')).assertEqual('https://a.com/x/l.js');
      // 裸相对按目录拼接；ref 带原样保留 query
      expect(resolveUrl('https://a.com/x/c.json', 'lib/l.js')).assertEqual('https://a.com/x/lib/l.js');
      expect(resolveUrl('https://a.com/x/c.json', './l.js?token=1')).assertEqual('https://a.com/x/l.js?token=1');
      // 相对引用不继承 base 的 query
      expect(resolveUrl('https://a.com/x/c.json?u=1', './l.js')).assertEqual('https://a.com/x/l.js');
      // base 非标准形态：原样返回 ref
      expect(resolveUrl('Not a url', './l.js')).assertEqual('./l.js');
      // 端口保留
      expect(resolveUrl('http://a.com:81/x/c.json', './l.js')).assertEqual('http://a.com:81/x/l.js');
    });
    it('resolveSiteUrls_inplace', 0, () => {
      const raw = JSON.parse('{'
        + '"sites":['
        + '{"key":"rel","name":"相对","type":3,"api":"./drpy_libs/drpy2.min.js","ext":"./drpy_js/北川.js"},'
        + '{"key":"jar","name":"类名","type":3,"api":"csp_Gz360"},'
        + '{"key":"abs","name":"绝对","type":1,"api":"https://c.example/api"},'
        + '{"key":"objext","name":"对象ext","type":3,"api":"https://d.example/x.js","ext":"{\\"url\\":\\"./rel/\\"}"}'
        + ']}') as Record<string, Object>;
      const cfg = parseTvboxConfig(raw);
      resolveSiteUrls(cfg, 'https://sub.example/box/8.10.json');
      expect(cfg.sites[0].api).assertEqual('https://sub.example/box/drpy_libs/drpy2.min.js');
      expect(cfg.sites[0].ext).assertEqual('https://sub.example/box/drpy_js/北川.js');
      // 类名与绝对地址不动；object 形态 ext（'{' 开头 JSON 串）天然不命中
      expect(cfg.sites[1].api).assertEqual('csp_Gz360');
      expect(cfg.sites[2].api).assertEqual('https://c.example/api');
      expect(cfg.sites[3].ext).assertEqual('{"url":"./rel/"}');
      // 相对化后变为受支持的 drpy 站
      expect(isSiteSupported(cfg.sites[0])).assertTrue();
    });
    it('tryConvertCspToCms_appys', 0, () => {
      // csp_AppYsV2 + ext URL → type4 appys
      const s1: SiteConfig = mkSite(3, 'csp_AppYsV2');
      s1.ext = 'https://api.example.com';
      expect(tryConvertCspToCms(s1)).assertTrue();
      expect(s1.type).assertEqual(4);
      expect(s1.api).assertEqual('https://api.example.com');
      expect(siteEngine(s1) === 'appys').assertTrue();
      expect(isSiteSupported(s1)).assertTrue();
    });
    it('tryConvertCspToCms_cms', 0, () => {
      // csp_Dovod + ext JSON URL → type1 cms
      const s2: SiteConfig = mkSite(3, 'csp_Dovod');
      s2.ext = '{"api":"https://cms.example.com/api.php"}';
      expect(tryConvertCspToCms(s2)).assertTrue();
      expect(s2.type).assertEqual(1);
      expect(s2.api).assertEqual('https://cms.example.com/api.php');
      expect(siteEngine(s2) === 'cms').assertTrue();
    });
    it('tryConvertCspToCms_noUrl', 0, () => {
      // csp_XYQHiker + ext 无 URL → 不转换
      const s3: SiteConfig = mkSite(3, 'csp_XYQHiker');
      s3.ext = '{"rule":"div.list","title":"a.title"}';
      expect(tryConvertCspToCms(s3)).assertFalse();
      expect(s3.type).assertEqual(3);
      expect(siteEngine(s3) === 'proxy').assertTrue();      // csp_* 未转换 → JAR 代理引擎（受支持）
      expect(isSiteSupported(s3)).assertTrue();
    });
  });
}
