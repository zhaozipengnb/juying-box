// 糯米影视（www.mlxdream.com）采集源：苹果CMS stui 模板，SSR 静态页。
// 分类 /tmi/{tid}.html（单页无分页）；详情 /dmi/{id}.html；选集 /pmi/{id}/{线路}/{集}.html
// （播放页 player_aaaa.url 内嵌 m3u8，通用解析可提取）；搜索 /ss.html?wd=。
// 条目名带 SEO 前后缀（[动作片]xxx免费观看），预处理 包一层清洗；图片为懒加载 data-original。
var rule = {
    title: '糯米影视',
    host: 'https://www.mlxdream.com',
    homeUrl: '/',
    url: '/tmi/fyclass.html',
    searchUrl: '/ss.html?wd=**',
    class_name: '电影&韩剧&日剧&美剧&综艺&动漫',
    class_url: 'dianying&hanju&riju&oumeiju&zongyi&dongman',
    pagecount: { 'dianying': 1, 'hanju': 1, 'riju': 1, 'oumeiju': 1, 'zongyi': 1, 'dongman': 1 },
    searchable: 1,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    推荐: 'body&&.stui-vodlist__box;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    一级: 'body&&.stui-vodlist__box;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    二级: {
        title: '.stui-content__detail&&h1&&Text',
        img: '.stui-content__thumb&&img&&data-original',
        tabs: '.nav-tabs&&li',
        tab_text: 'a&&Text',
        lists: '.stui-content__playlist:eq(#id)&&li',
        list_text: 'a&&Text',
        list_url: 'a&&href'
    },
    搜索: 'body&&.stui-vodlist__box;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    play_parse: false,
    预处理: `js:
(function () {
    var D = globalThis.__DRPY;
    if (!D) { return; }
    function clean(s) {
        var r;
        try { r = JSON.parse(s); } catch (e) { return s; }
        var list = r.list || [];
        for (var i = 0; i < list.length; i++) {
            list[i].vod_name = String(list[i].vod_name || '')
                .replace(/^\\[[^\\]]*\\]/, '').replace(/免费观看$/, '');
        }
        return JSON.stringify(r);
    }
    var rawCat = D.category, rawHv = D.homeVod, rawSearch = D.search;
    D.category = function (tid, pg) { return clean(rawCat(tid, pg)); };
    D.homeVod = function () { return clean(rawHv()); };
    D.search = function (wd, quick) { return clean(rawSearch(wd, quick)); };
})();
`
};
