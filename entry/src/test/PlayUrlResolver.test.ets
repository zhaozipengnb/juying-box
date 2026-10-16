import { describe, it, expect } from '@ohos/hypium';
import { FetchText, extractMediaUrl, isDirectMedia, resolvePlayUrl, unwrapParseQuery } from 'common';

// fixture：合成播放页（非真实站点数据）
const MACCMS_PAGE: string = '<html><head><script type="text/javascript">var player_aaaa={"flag":"lzm3u8",' +
  '"encrypt":"0","url":"https:\\/\\/cdn.demo.com\\/2026\\/abc\\/index.m3u8","id":"1"}</script></head>' +
  '<body><div id="play"></div></body></html>';
const SOURCE_TAG_PAGE: string = '<html><body><video controls src="https://cdn.demo.com/live/1.mp4"></video></body></html>';
const PLAIN_HTML: string = '<html><body><h1>404</h1><p>页面不存在</p></body></html>';
// 真实形态取样：MacCMS 分享播放页（量子直连 v.lzcdn27.com/share/<id>），地址为带签名的相对路径
const SHARE_PAGE: string = '<html><head><title>了不起啊朋友01</title></head><body onload="init()">' +
  '<script type="text/javascript">var video_player= \'artplayer\';var redirecturl = "http://vip.okzybo.com";' +
  'var videoid = "2cfd22322a832d773c4218f4559fa174";var id = \'2cfd22322a832d773c4218f4559fa174\'' +
  'var main = "/20261014/19136_d03bb904/index.m3u8?sign=035d2f8decd201ebc01f8c8452926568";' +
  'var xml = "/20261014/19136_d03bb904/index.xml?sign=035d2f8decd201ebc01f8c8452926568";</script></body></html>';

export default function playUrlResolverTest() {
  describe('PlayUrlResolverTest', () => {

    it('isDirectMedia', 0, () => {
      expect(isDirectMedia('https://a/b/index.m3u8')).assertTrue();
      expect(isDirectMedia('https://a/b/index.m3u8?sign=1&t=2')).assertTrue();
      expect(isDirectMedia('http://a/x.mp4')).assertTrue();
      expect(isDirectMedia('https://a/play/123-1-1.html')).assertFalse();
      expect(isDirectMedia('https://jx.demo.com/?url=https://a/b.m3u8')).assertFalse();
    });

    it('unwrapParseQuery', 0, () => {
      expect(unwrapParseQuery('https://jx.demo.com/?url=https%3A%2F%2Fa%2Fb.m3u8')).assertEqual('https://a/b.m3u8');
      expect(unwrapParseQuery('https://jx.demo.com/?url=https://a/b.html')).assertEqual('https://a/b.html');
      // 非 URL 的 id 参数不算解析接口
      expect(unwrapParseQuery('https://a/play?id=99')).assertEqual('');
      expect(unwrapParseQuery('https://a/play/1-1-1.html')).assertEqual('');
    });

    it('extract_maccms_player_json', 0, () => {
      // player_aaaa 里的地址是 JS 转义形态，需还原
      expect(extractMediaUrl(MACCMS_PAGE, 'https://site.demo.com/play/1-1-1.html'))
        .assertEqual('https://cdn.demo.com/2026/abc/index.m3u8');
    });

    it('extract_source_tag', 0, () => {
      expect(extractMediaUrl(SOURCE_TAG_PAGE, 'https://site.demo.com/play/2'))
        .assertEqual('https://cdn.demo.com/live/1.mp4');
    });

    it('extract_none_on_plain_html', 0, () => {
      expect(extractMediaUrl(PLAIN_HTML, 'https://site.demo.com/play/3')).assertEqual('');
    });

    it('extract_share_page_relative_main', 0, () => {
      // 页面里先出现 redirecturl/videoid 等无关赋值，取到的必须是 main 的 m3u8 并绝对化
      expect(extractMediaUrl(SHARE_PAGE, 'https://v.lzcdn27.com/share/2cfd22322a832d773c4218f4559fa174'))
        .assertEqual('https://v.lzcdn27.com/20261014/19136_d03bb904/index.m3u8?sign=035d2f8decd201ebc01f8c8452926568');
    });

    it('resolve_direct_passthrough', 0, async () => {
      let called: boolean = false;
      const fetchText: FetchText = (url: string): Promise<string> => {
        called = true;
        return Promise.resolve('');
      };
      const out: string = await resolvePlayUrl('https://cdn.demo.com/a/index.m3u8', fetchText);
      expect(out).assertEqual('https://cdn.demo.com/a/index.m3u8');
      expect(called).assertFalse();  // 直链不发起额外请求
    });

    it('resolve_play_page', 0, async () => {
      const fetchText: FetchText = (url: string): Promise<string> => {
        return Promise.resolve(url.indexOf('play') >= 0 ? MACCMS_PAGE : '');
      };
      const out: string = await resolvePlayUrl('https://site.demo.com/play/1-1-1.html', fetchText);
      expect(out).assertEqual('https://cdn.demo.com/2026/abc/index.m3u8');
    });

    it('resolve_parse_api_body_is_direct', 0, async () => {
      // 解析接口响应体就是直链（常见于 jx 接口）
      const fetchText: FetchText = (): Promise<string> => Promise.resolve('https://cdn.demo.com/jx/index.m3u8\n');
      const out: string = await resolvePlayUrl('https://jx.demo.com/?url=https%3A%2F%2Fv.qq.com%2Fx.html', fetchText);
      expect(out).assertEqual('https://cdn.demo.com/jx/index.m3u8');
    });

    it('resolve_parse_api_nested_page', 0, async () => {
      // 解析接口返回的是内层播放页 → 再下钻一层取直链
      const fetchText: FetchText = (url: string): Promise<string> => {
        return Promise.resolve(url.indexOf('jx.demo.com') >= 0 ? PLAIN_HTML : MACCMS_PAGE);
      };
      const out: string = await resolvePlayUrl('https://jx.demo.com/?url=https%3A%2F%2Fsite.demo.com%2Fplay%2F9-1-1.html', fetchText);
      expect(out).assertEqual('https://cdn.demo.com/2026/abc/index.m3u8');
    });

    it('resolve_unresolvable_returns_input', 0, async () => {
      const fetchText: FetchText = (): Promise<string> => Promise.resolve(PLAIN_HTML);
      const out: string = await resolvePlayUrl('https://site.demo.com/play/dead.html', fetchText);
      expect(out).assertEqual('https://site.demo.com/play/dead.html');
    });

    it('resolve_fetch_error_returns_input', 0, async () => {
      const fetchText: FetchText = (): Promise<string> => Promise.reject(new Error('net down'));
      const out: string = await resolvePlayUrl('https://site.demo.com/play/err.html', fetchText);
      expect(out).assertEqual('https://site.demo.com/play/err.html');
    });
  });
}
