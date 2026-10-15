import { describe, it, expect } from '@ohos/hypium';
import { decodeConfigContent, ConfigDecodeError, utf8Encode, b64encode } from 'common';

// 合成最小配置（不得使用真实订阅数据落盘，spec §11）
const SAMPLE_JSON5 =
  '{\r\n"spider":"http://x/s.jpg;md5;aa",\r\n' +
  '//{"key":"注释站点","type":9},\r\n' +
  '"sites":[{"key":"a","name":"甲站","type":1,"api":"http://a/api.php"}]\r\n}';

export default function configDecoderTest() {
  describe('ConfigDecoderTest', () => {
    it('plain_json5', 0, () => {
      const cfg = decodeConfigContent(SAMPLE_JSON5);
      expect(cfg.sites.length).assertEqual(1);
      expect(cfg.sites[0].name).assertEqual('甲站');
      expect(cfg.spider).assertEqual('http://x/s.jpg;md5;aa');
    });
    it('base64_layer', 0, () => {
      const cfg = decodeConfigContent(b64encode(utf8Encode(SAMPLE_JSON5)));
      expect(cfg.sites.length).assertEqual(1);
    });
    it('jpeg_steg_with_salt', 0, () => {
      // 最小 JPEG 壳：JFIF 头 + FFD9 结束符 + 盐 + base64
      const head = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0xff, 0xd9]);
      const tailStr = 'odvEMkqU**e' + b64encode(utf8Encode(SAMPLE_JSON5));
      const tail = utf8Encode(tailStr);
      const all = new Uint8Array(head.length + tail.length);
      all.set(head, 0); all.set(tail, head.length);
      const cfg = decodeConfigContent(all);
      expect(cfg.sites.length).assertEqual(1);
      expect(cfg.sites[0].type).assertEqual(1);
    });
    it('garbage_throws', 0, () => {
      let threw = false;
      try { decodeConfigContent('随便乱写'); } catch (e) { threw = e instanceof ConfigDecodeError; }
      expect(threw).assertTrue();
    });
    it('dirty_realworld_json5', 0, () => {
      // 真实订阅源脏数据：字符串值内含原始换行/制表符 + 行首注释 + 行尾注释（真实源 xhztv 形态）
      const dirty =
        '{\n"sites":[\n//注释站点行\n' +
        '{"key":"a","name":"优\n酷站","type":1,"api":"http://a/api.php","filterable":1},\n' +
        '{"key":"b","name":"脏\t名","type":1,"api":"http://b/api.php"} // 行尾注释\n' +
        ']}';
      const cfg = decodeConfigContent(dirty);
      expect(cfg.sites.length).assertEqual(2);
      expect(cfg.sites[0].name).assertEqual('优酷站');
      expect(cfg.sites[1].name).assertEqual('脏名');
    });
  });
}
