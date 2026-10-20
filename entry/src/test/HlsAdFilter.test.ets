// HlsAdFilter 单测：fixture 合成播放列表，覆盖分块去广告 / 绝对化 / master 改写 / SEQUENCE 排除
import { describe, it, expect } from '@ohos/hypium';
import { AD_MAX_SEC, CONTENT_MIN_SEC, filterHlsPlaylist, filterMediaPlaylist, isMasterPlaylist } from 'common';

// 内容块 150s（25×6s）+ 广告块 30s + 内容块 150s（相对片段地址）
function contentBlock(startIdx: number): string {
  let s: string = '';
  for (let i = 0; i < 25; i++) { s += '#EXTINF:6.0,\nseg/' + (startIdx + i) + '.ts\n'; }
  return s;
}
const MEDIA_WITH_AD: string = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:631\n'
  + contentBlock(1)
  + '#EXT-X-DISCONTINUITY\n#EXTINF:5.0,\nads/a1.ts\n#EXTINF:5.0,\nads/a2.ts\n#EXTINF:20.0,\nads/a3.ts\n'
  + '#EXT-X-DISCONTINUITY\n' + contentBlock(26);

// 全部为短块（无从分辨内容/广告）：15s + 20s
const MEDIA_ALL_SHORT: string = '#EXTM3U\n'
  + '#EXT-X-DISCONTINUITY\n#EXTINF:15.0,\ns1.ts\n'
  + '#EXT-X-DISCONTINUITY\n#EXTINF:20.0,\ns2.ts';

// KEY 相对 URI + 纯内容单块
const MEDIA_WITH_KEY: string = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="keys/k1.key",IV=0x1\n#EXTINF:6.0,\nseg/01.ts';

const MASTER: string = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n2000k/hls/index.m3u8\n'
  + '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n4000k/hls/index.m3u8';

const BASE: string = 'https://cdn.example.com/vod/2026/a1/index.m3u8';

export default function hlsAdFilterTest() {
  describe('hlsAdFilterTest', () => {
    it('is_master_playlist', 0, () => {
      expect(isMasterPlaylist(MASTER)).assertTrue();
      expect(isMasterPlaylist(MEDIA_WITH_AD)).assertFalse();
    });

    it('media_ad_block_removed', 0, () => {
      expect(CONTENT_MIN_SEC).assertEqual(120);
      const out: string = filterMediaPlaylist(MEDIA_WITH_AD, BASE);
      expect(out.indexOf('ads/a1.ts') < 0).assertTrue();          // 广告块整体剔除
      expect(out.indexOf('ads/a3.ts') < 0).assertTrue();
      expect(out.indexOf('https://cdn.example.com/vod/2026/a1/seg/1.ts') >= 0).assertTrue();   // 内容块保留+绝对化
      expect(out.indexOf('https://cdn.example.com/vod/2026/a1/seg/26.ts') >= 0).assertTrue();
      // 保留块之间补一个 DISCONTINUITY（块间时间戳跳变仍在）
      const discontCount: number = out.split('#EXT-X-DISCONTINUITY').length - 1;
      expect(discontCount).assertEqual(1);
      // 广告块被移除：仅剩 2×25 条 EXTINF
      const extinfCount: number = out.split('#EXTINF').length - 1;
      expect(extinfCount).assertEqual(50);
    });

    it('media_all_short_untouched', 0, () => {
      // 少量短块（< MERGE_MIN_GROUPS）→ 原样放行，仅绝对化
      const out: string = filterMediaPlaylist(MEDIA_ALL_SHORT, BASE);
      expect(out.indexOf('s1.ts') >= 0).assertTrue();
      expect(out.indexOf('s2.ts') >= 0).assertTrue();
      const discontCount: number = out.split('#EXT-X-DISCONTINUITY').length - 1;
      expect(discontCount).assertEqual(2);   // 两个边界都保留（少量短块不合并）
    });

    it('media_many_short_blocks_merged', 0, () => {
      // 牛牛型防采集结构：9 个短块、无内容锚点 → 去掉全部 DISCONTINUITY 合并单流
      let many: string = '#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n';
      for (let b = 0; b < 9; b++) {
        many += '#EXT-X-DISCONTINUITY\n#EXTINF:2.0,\nblk' + b + '/s1.ts\n';
      }
      many += '#EXT-X-ENDLIST';
      const out: string = filterMediaPlaylist(many, BASE);
      expect(out.indexOf('#EXT-X-DISCONTINUITY') < 0).assertTrue();  // 标记全部移除
      expect(out.indexOf('blk0/s1.ts') >= 0).assertTrue();           // 片段全保留
      expect(out.indexOf('blk8/s1.ts') >= 0).assertTrue();
      expect(out.indexOf('https://cdn.example.com/vod/2026/a1/blk0/s1.ts') >= 0).assertTrue();  // 绝对化
      expect(out.indexOf('#EXT-X-ENDLIST') >= 0).assertTrue();       // 尾部标签不丢
    });

    it('media_key_uri_absolutized', 0, () => {
      const out: string = filterMediaPlaylist(MEDIA_WITH_KEY, BASE);
      expect(out.indexOf('https://cdn.example.com/vod/2026/a1/keys/k1.key') >= 0).assertTrue();
    });

    it('discontinuity_sequence_not_boundary', 0, () => {
      // DISCONTINUITY-SEQUENCE 是全局序号标签，不是分块边界：不应产生新块
      const withSeq: string = '#EXTM3U\n#EXT-X-DISCONTINUITY-SEQUENCE:0\n#EXTINF:150.0,\na.ts\n#EXTINF:150.0,\nb.ts';
      const out: string = filterMediaPlaylist(withSeq, BASE);
      expect(out.indexOf('a.ts') >= 0).assertTrue();
      expect(out.indexOf('b.ts') >= 0).assertTrue();
      expect(out.split('#EXT-X-DISCONTINUITY\n').length - 1).assertEqual(0);  // 无补插边界
    });

    it('master_variants_wrapped', 0, () => {
      const wrapped: string = filterHlsPlaylist(MASTER, BASE, (u: string): string => 'http://127.0.0.1:1/f/' + u);
      expect(wrapped.indexOf('http://127.0.0.1:1/f/https://cdn.example.com/vod/2026/a1/2000k/hls/index.m3u8\n') >= 0).assertTrue();
      expect(wrapped.indexOf('http://127.0.0.1:1/f/https://cdn.example.com/vod/2026/a1/4000k/hls/index.m3u8') >= 0).assertTrue();
      // 原相对子列表行不再独立存在（行首不带 https 协议改写前缀的裸相对行应消失）
      expect(wrapped.indexOf('\n2000k/hls/index.m3u8') < 0).assertTrue();
    });

    it('ad_max_threshold', 0, () => {
      expect(AD_MAX_SEC).assertEqual(60);
    });
  });
}
