// Idn 单元测试：中文域名 → punycode（RFC 3492）转码正确性。
// 期望值均经 python idna 库独立验证：影视仓→xn--5mqx81b535a、中文→xn--fiq228c、例例→xn--fsqa。
import { describe, it, expect } from '@ohos/hypium';
import { toPunycodeUrl } from '../main/ets/net/Idn';

export default function idnTest() {
  describe('IdnTest', () => {
    it('chinese_domain', 0, () => {
      // 中文域名整体转 xn-- 形式，scheme 与路径保持不变
      expect(toPunycodeUrl('http://影视仓.com/config')).assertEqual('http://xn--5mqx81b535a.com/config');
    });
    it('ascii_untouched', 0, () => {
      // 纯 ASCII 域名原样返回，不加 xn-- 前缀
      expect(toPunycodeUrl('http://xhztv.top/4k.json')).assertEqual('http://xhztv.top/4k.json');
    });
    it('port_preserved', 0, () => {
      // 域名转码后端口原样保留
      expect(toPunycodeUrl('http://中文.cn:8080/x')).assertEqual('http://xn--fiq228c.cn:8080/x');
    });
    it('https_path_preserved', 0, () => {
      // 仅域名参与转码，路径中的中文原样保留
      expect(toPunycodeUrl('https://例例.com/路径/文件.json')).assertEqual('https://xn--fsqa.com/路径/文件.json');
    });
    it('no_scheme_untouched', 0, () => {
      // 无 :// 前缀的字符串（即使含中文）原样返回
      expect(toPunycodeUrl('影视仓.com/config')).assertEqual('影视仓.com/config');
    });
  });
}
