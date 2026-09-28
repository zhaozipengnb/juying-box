// 暂存路径，收口时迁移至 entry/src/test/
import { describe, it, expect } from '@ohos/hypium';
import { utf8Encode, utf8Decode, b64encode, b64decode, stripNonB64 } from '../../../common';

describe('CodingTest', () => {
  it('utf8_roundtrip_chinese', 0, () => {
    const s = '饭太硬订阅站长┃不卡';
    expect(utf8Decode(utf8Encode(s))).assertEqual(s);
  });
  it('b64_roundtrip', 0, () => {
    const bytes = utf8Encode('{"sites":[]}');
    const enc = b64encode(bytes);
    expect(enc).assertEqual('eyJzaXRlcyI6W119');
    const dec = b64decode(enc);
    expect(utf8Decode(dec)).assertEqual('{"sites":[]}');
  });
  it('b64decode_tolerant', 0, () => {
    const dec = b64decode('eyJza\r\nXRlc\nyI 6W119');
    expect(utf8Decode(dec)).assertEqual('{"sites":[]}');
  });
  it('b64decode_salt_padding', 0, () => {
    // 盐为纯非字母表字符会被剔除；合法字母表字符组成的盐由 ConfigDecoder 的偏移探测处理，不在此测；另验证无 padding 也可解
    const dec = b64decode(stripNonB64('!!**盐**!!') + 'eyJzaXRlcyI6W119');
    expect(utf8Decode(dec)).assertEqual('{"sites":[]}');
  });
  it('stripNonB64', 0, () => {
    expect(stripNonB64('ab\r\nc\n d*e=')).assertEqual('abcde=');
  });
});
