// 天狼影视（www.dalaocoder.com）采集源：全命令式（预处理 覆盖）。
// 站点为混淆 class 的自定义模板：分类 /aa262/{tid}.html、分页 /aa262/{tid}/{pg}.html、
// 详情 /aa263/{slug}.html → 播放页 /m9s{xx}/{slug}.html（前缀按片混淆）→ 选集链接
// /m9s{xx}/{slug}/{N}.html，同一链接把 .html 换成 .mp4 即媒体直链（实测恒成立）。
// 搜索页结果结构无法稳定解析，searchable 关闭。分类页条目用正则提取（混淆 class 名）。
var rule = {
    title: '天狼影视',
    host: 'https://www.dalaocoder.com',
    homeUrl: '/',
    url: '/aa262/fyclass.html',
    class_name: '电影&电视剧&动漫&综艺&短剧&体育',
    class_url: '1&2&3&4&5&27',
    searchable: 0,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    play_parse: false,
    预处理: `js:
(function () {
    var D = globalThis.__DRPY;
    if (!D) { return; }
    var HOST = 'https://www.dalaocoder.com';
    var UA = rule.headers['User-Agent'];
    function abs(u) { return u.indexOf('http') === 0 ? u : HOST + u; }

    // 通用条目提取：.pic>a[href*=/aa263/]（class 混淆，用正则定位）
    function parseItems(html) {
        var out = [], seen = {};
        var re = /<a href="(\\/aa263\\/[a-z0-9]+\\.html)" title="([^"]+)"[\\s\\S]{0,200}?data-src="([^"]+)"/g;
        var m;
        while ((m = re.exec(html))) {
            if (seen[m[1]]) { continue; }
            seen[m[1]] = 1;
            out.push({ vod_id: abs(m[1]), vod_name: m[2], vod_pic: abs(m[3]), vod_remarks: '' });
        }
        return out;
    }

    D.home = function () {
        var ids = ['1', '2', '3', '4', '5', '27'];
        var names = ['电影', '电视剧', '动漫', '综艺', '短剧', '体育'];
        var cs = [];
        for (var i = 0; i < ids.length; i++) { cs.push({ type_id: ids[i], type_name: names[i] }); }
        return JSON.stringify({ class: cs });
    };

    D.homeVod = function () {
        var html = req(HOST + '/', { headers: { 'User-Agent': UA } }).content;
        return JSON.stringify({ list: parseItems(html) });
    };

    D.category = function (tid, pg) {
        var page = parseInt(pg, 10) || 1;
        var html = req(HOST + '/aa262/' + tid + '/' + page + '.html', { headers: { 'User-Agent': UA } }).content;
        var list = parseItems(html);
        return JSON.stringify({ list: list, page: page, pagecount: list.length >= 20 ? page + 1 : page });
    };

    D.detail = function (ids) {
        var url = String(ids).split(',')[0].trim();
        var html = req(url, { headers: { 'User-Agent': UA } }).content;
        var title = (html.match(/<h1[^>]*>([\\s\\S]{0,80}?)<\\/h1>/) || ['', ''])[1].replace(/<[^>]+>/g, '').trim()
            || (html.match(/property="og:title" content="([^"]+)"/) || ['', ''])[1]
            || (html.match(/<a href="\\/aa263\\/[a-z0-9]+\\.html" title="([^"]+)"/) || ['', ''])[1];
        var img = (html.match(/<a href="\\/aa263\\/[a-z0-9]+\\.html"[^>]*>[\\s\\S]{0,160}?data-src="([^"]+)"/) || ['', ''])[1];
        var desc = (html.match(/剧情[：:]<\\/?strong[^>]*>([\\s\\S]{0,500}?)<\\//) || ['', ''])[1].replace(/<[^>]+>/g, '').trim();
        var playSlug = (html.match(/href="(\\/m9s[a-z]+\\/[a-z0-9]+)\\.html"/) || [''])[1];
        if (!playSlug) { throw new Error('详情无播放入口'); }
        var ps = req(abs(playSlug + '.html'), { headers: { 'User-Agent': UA } }).content;
        // 选集：/m9s{xx}/{slug}/{N}.html → 同路径 .mp4 直链
        var eps = [], seen = {};
        var re = /<a href="(\\/m9s[a-z]+\\/[a-z0-9]+\\/(\\d+))\\.html"([^>]*)>/g;
        var m;
        while ((m = re.exec(ps))) {
            if (seen[m[2]]) { continue; }
            seen[m[2]] = 1;
            var dn = (m[3].match(/data-name="([^"]*)"/) || ['', ''])[1];
            eps.push({ n: parseInt(m[2], 10), s: (dn || ('第' + (eps.length + 1) + '集')) + '$' + abs(m[1] + '.mp4') });
        }
        if (!eps.length) { throw new Error('未取到选集'); }
        eps.sort(function (a, b) { return a.n - b.n; });
        return JSON.stringify({
            list: [{
                vod_id: url, vod_name: title, vod_pic: abs(img), vod_content: desc,
                vod_play_from: '天狼影视', vod_play_url: eps.map(function (e) { return e.s; }).join('#')
            }]
        });
    };

    D.play = function (flag, id) {
        return JSON.stringify({ url: String(id), parse: 0 });
    };
})();
`
};
