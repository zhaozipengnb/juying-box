// 暂存路径，收口时迁移至 entry/src/test/
import { describe, it, expect } from '@ohos/hypium';
import { toInt, toStr, parseTvboxConfig } from '../../../common';

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
});
