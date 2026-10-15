import { describe, it, expect } from '@ohos/hypium';
import { CmsJsonApi, FetchText, SiteConfig } from 'common';

const SITE: SiteConfig = {
  key: 'cms', name: 'CMS测试站', type: 1, api: 'http://demo/api.php',
  searchable: 1, quickSearch: 1, filterable: 0, timeout: 10000, playerType: 0,
  jar: '', ext: '', header: {}
};

// fixture：合成 MacCMS 响应（非真实站点数据）
const FIXTURE: Record<string, string> = {
  'http://demo/api.php?ac=list':
    '{"class":[{"type_id":1,"type_name":"电影"},{"type_id":2,"type_name":"剧集"}],"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"","vod_remarks":""}]}',
  'http://demo/api.php?ac=videolist&pg=1':
    '{"page":1,"pagecount":3,"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"}]}',
  'http://demo/api.php?ac=videolist&t=1&pg=1':
    '{"page":1,"pagecount":3,"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"},{"vod_id":12,"vod_name":"片B","vod_pic":"","vod_remarks":"HD"}]}',
  'http://demo/api.php?ac=detail&ids=11':
    '{"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集","type_name":"电影","vod_year":"2024","vod_actor":"甲,乙","vod_director":"丙","vod_content":"简介&lt;img src=x&gt;","vod_play_from":"线路1$$$线路2","vod_play_url":"第01集$http://v/1.m3u8#第02集$http://v/2.m3u8$$$正片$http://v/b.mp4"}]}',
  'http://demo/api.php?ac=detail&wd=片A':
    '{"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"}]}'
};

const fakeFetch: FetchText = (url: string): Promise<string> => {
  // 实现层对搜索词做 URL 编码，fake 侧先解码再查 fixture 表
  return Promise.resolve(FIXTURE[decodeURIComponent(url)] ?? '{"list":[]}');
};

export default function cmsJsonApiTest() {
  describe('CmsJsonApiTest', () => {
    const api = new CmsJsonApi(SITE, fakeFetch);

    it('home_content', 0, async () => {
      const home = await api.getHomeContent();
      expect(home.categories.length).assertEqual(2);
      expect(home.categories[0].tid).assertEqual('1');
      expect(home.items.length).assertEqual(1);
      expect(home.items[0].name).assertEqual('片A');
    });
    it('category_page', 0, async () => {
      const page = await api.categoryContent('1', 1);
      expect(page.pageCount).assertEqual(3);
      expect(page.items.length).assertEqual(2);
      expect(page.items[1].remark).assertEqual('HD');
    });
    it('detail_lines_episodes', 0, async () => {
      const d = await api.detailContent(['11']);
      expect(d.lines.length).assertEqual(2);
      expect(d.lines[0].from).assertEqual('线路1');
      expect(d.lines[0].episodes.length).assertEqual(2);
      expect(d.lines[0].episodes[1].url).assertEqual('http://v/2.m3u8');
      expect(d.lines[1].episodes[0].name).assertEqual('正片');
      expect(d.desc.indexOf('<img') < 0).assertTrue(); // 简介需剥 HTML 标签
    });
    it('search', 0, async () => {
      const r = await api.searchContent('片A', false);
      expect(r.items.length).assertEqual(1);
    });
    it('resolve_relative_url', 0, () => {
      expect(CmsJsonApi.resolvePlayUrl(SITE, '/play/1.html')).assertEqual('http://demo/play/1.html');
      expect(CmsJsonApi.resolvePlayUrl(SITE, 'http://x/y.m3u8')).assertEqual('http://x/y.m3u8');
    });
  });
}
