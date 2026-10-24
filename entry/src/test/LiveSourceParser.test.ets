// LiveSourceParser 单测：m3u / txt 双格式 fixture
import { describe, it, expect } from '@ohos/hypium';
import { parseLiveSource, parseM3u, parseTxt } from 'common';

const M3U = '#EXTM3U\n' +
  '#EXTINF:-1 tvg-id="cctv1" group-title="央视",CCTV-1\n' +
  'http://live/cctv1.m3u8\n' +
  '#EXTINF:-1 group-title="央视",CCTV-2\n' +
  'http://live/cctv2.m3u8\n' +
  '#EXTINF:-1 group-title="卫视",湖南卫视\n' +
  'http://live/hntv.m3u8\n' +
  '#EXTINF:-1,未组频道\n' +
  'http://live/misc.m3u8\n';

const TXT = '央视频道,#genre#\n' +
  'CCTV-1,http://live/cctv1.m3u8\n' +
  'CCTV-2,http://live/cctv2.m3u8\n' +
  '卫视频道,#genre#\n' +
  '湖南卫视,http://live/hntv.m3u8\n' +
  '坏行没有逗号\n' +
  '广东卫视,ftp://bad-scheme 丢弃\n';

export default function liveSourceParserTest() {
  describe('liveSourceParserTest', () => {
    it('auto_detect_m3u', 0, () => {
      const gs = parseLiveSource(M3U);
      expect(gs.length).assertEqual(3);   // 央视/卫视/未分组
      expect(gs[0].name).assertEqual('央视');
      expect(gs[0].channels.length).assertEqual(2);
      expect(gs[0].channels[0].name).assertEqual('CCTV-1');
      expect(gs[2].name).assertEqual('未分组');
    });

    it('m3u_group_and_url', 0, () => {
      const gs = parseM3u(M3U);
      const ws = gs.find((g) => g.name === '卫视');
      expect(ws !== undefined).assertTrue();
      expect(ws!.channels[0].url).assertEqual('http://live/hntv.m3u8');
    });

    it('txt_genre_switch_and_bad_lines', 0, () => {
      const gs = parseTxt(TXT);
      expect(gs.length).assertEqual(2);
      expect(gs[0].name).assertEqual('央视频道');
      expect(gs[0].channels.length).assertEqual(2);
      expect(gs[1].name).assertEqual('卫视频道');
      expect(gs[1].channels.length).assertEqual(1);   // 坏行与非 http 行被跳过
      expect(gs[1].channels[0].name).assertEqual('湖南卫视');
    });

    it('auto_detect_txt', 0, () => {
      const gs = parseLiveSource(TXT);
      expect(gs.length).assertEqual(2);
    });

    it('empty_input', 0, () => {
      expect(parseLiveSource('').length).assertEqual(0);
      expect(parseLiveSource('\n\n').length).assertEqual(0);
    });
  });
}
