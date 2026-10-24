// 港剧影视（eftyne.waayf.cn）采集源：Bootstrap 自定义模板电影站，SSR 静态页。
// 分类 /fan_movie_test/{tid}.html（单页全量，无分页）；详情 /fan_movie_test/movie/{id}.html；
// 播放 /fan_movie_test/play/{id}.html（HTML 内嵌 m3u8 直链，通用解析可提取）。
// 无搜索功能；单片只有一个播放入口，字符串二级表达不了，detail 用 预处理 覆盖为命令式。
var rule = {
    title: '港剧影视',
    host: 'https://eftyne.waayf.cn',
    homeUrl: '/',
    url: '/fan_movie_test/fyclass.html',
    class_name: '动作&喜剧&爱情&科幻&恐怖&剧情&战争',
    class_url: 'dongzuo-pian&xiju-pian&aiqing-pian&kehuan-pian&kongbu-pian&juqing-pian&zhanzheng-pian',
    pagecount: {
        'dongzuo-pian': 1, 'xiju-pian': 1, 'aiqing-pian': 1, 'kehuan-pian': 1,
        'kongbu-pian': 1, 'juqing-pian': 1, 'zhanzheng-pian': 1
    },
    searchable: 0,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    推荐: 'body&&.movie-card;img&&alt;img&&src;.muted&&Text;a&&href',
    一级: 'body&&.movie-card;img&&alt;img&&src;.muted&&Text;a&&href',
    play_parse: false,
    预处理: `js:
(function () {
    var D = globalThis.__DRPY;
    if (!D) { return; }
    var HOST = 'https://eftyne.waayf.cn';
    var UA = rule.headers['User-Agent'];
    function abs(u) { return u.indexOf('http') === 0 ? u : HOST + u; }
    D.detail = function (ids) {
        var url = String(ids).split(',')[0].trim();
        var html = req(url, { headers: { 'User-Agent': UA } }).content;
        var title = (html.match(/<h1[^>]*>([^<]+)<\\/h1>/) || ['', ''])[1].trim();
        var img = (html.match(/movie-card[^>]*>\\s*<img[^>]+src="([^"]+)"/) || ['', ''])[1];
        var director = (html.match(/导演：<\\/strong>([^<]+)</) || ['', ''])[1].trim();
        var actor = (html.match(/主演：<\\/strong>([^<]+)</) || ['', ''])[1].trim();
        var tags = [];
        var tm, tr = /<span class="tag">([^<]+)<\\/span>/g;
        while ((tm = tr.exec(html))) { if (tags.indexOf(tm[1]) < 0) { tags.push(tm[1]); } }
        var pm = html.match(/href="([^"\\s]*\\/play\\/[^"\\s]*\\.html)"/);
        if (!pm) { throw new Error('无播放入口'); }
        var play = abs(pm[1]);
        return JSON.stringify({
            list: [{
                vod_id: url, vod_name: title, vod_pic: abs(img),
                vod_actor: actor, vod_director: director, type_name: tags.join(','),
                vod_play_from: '港剧影视', vod_play_url: '正片$' + play
            }]
        });
    };
})();
`
};
