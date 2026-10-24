// 情缘影视（qydqjt.com）采集源：苹果CMS stui 模板，SSR 静态页。
// 分类 /qydc/{tid}/（分页链接为 JS 生成、URL 参数无效，单页接入）；详情 /qydd/{id}/。
// 详情页各线路选集为懒加载（/play-eps/{vid}-{sid}-1/ 返回 JSON [{t,u}]），字符串二级
// 取不到且空线路会拼出脏地址，detail 用 预处理 覆盖为命令式（跳过空线路）。
// 选集 /play/{id}-{线路}-{集}/ 播放页 videoSrc 变量内嵌 m3u8，通用解析可提取。
var rule = {
    title: '情缘影视',
    host: 'https://qydqjt.com',
    homeUrl: '/',
    url: '/qydc/fyclass/',
    class_name: '电影&电视剧&动漫&综艺&纪录片',
    class_url: 'dianying&dianshiju&dongman&zongyi&jilupian',
    pagecount: { 'dianying': 1, 'dianshiju': 1, 'dongman': 1, 'zongyi': 1, 'jilupian': 1 },
    searchable: 0,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    推荐: 'body&&.stui-vodlist__box;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    一级: 'body&&.stui-vodlist__box;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    play_parse: false,
    预处理: `js:
(function () {
    var D = globalThis.__DRPY;
    if (!D) { return; }
    var HOST = 'https://qydqjt.com';
    var UA = rule.headers['User-Agent'];
    function abs(u) { return u.indexOf('http') === 0 ? u : HOST + u; }

    D.detail = function (ids) {
        var url = String(ids).split(',')[0].trim();
        var vid = (url.match(/\\/qydd\\/(\\d+)/) || ['', ''])[1];
        if (!vid) { throw new Error('详情地址无法解析:' + url); }
        var html = req(url, { headers: { 'User-Agent': UA } }).content;
        var title = (html.match(/stui-content__detail[\\s\\S]{0,120}?<h1[^>]*>([^<]+)<\\/h1>/) || ['', ''])[1].trim();
        var img = (html.match(/stui-content__thumb[\\s\\S]{0,200}?data-original="([^"]+)"/) || ['', ''])[1];
        var desc = (html.match(/class="desc[^"]*"[^>]*>([\\s\\S]{0,600}?)<\\//) || ['', ''])[1]
            .replace(/<[^>]+>/g, '').trim();
        var tabNames = [];
        var tm, tr = /id="playlisttab"[\\s\\S]{0,1500}?<\\/ul>/.exec(html);
        if (tr) {
            var nr = /font-size:14px;">([^<]+)</g;
            while ((tm = nr.exec(tr[0]))) { tabNames.push(tm[1].trim()); }
        }
        var sids = [];
        var sr = /id="playline\\d+"[^>]*data-sid="(\\d+)"/g;
        while ((tm = sr.exec(html))) { sids.push(tm[1]); }
        var froms = [], groups = [];
        for (var i = 0; i < sids.length; i++) {
            var r = req(HOST + '/play-eps/' + vid + '-' + sids[i] + '-1/', { headers: { 'User-Agent': UA } }).content;
            var arr;
            try { arr = JSON.parse(r); } catch (e) { continue; }
            if (!Array.isArray(arr) || !arr.length) { continue; }
            var segs = [];
            for (var k = 0; k < arr.length; k++) {
                var name = arr[k].t || ('第' + (k + 1) + '集');
                segs.push(name + '$' + abs(arr[k].u));
            }
            froms.push(tabNames[i] || ('线路' + (i + 1)));
            groups.push(segs.join('#'));
        }
        if (!groups.length) { throw new Error('全部线路均无选集'); }
        return JSON.stringify({
            list: [{
                vod_id: url, vod_name: title, vod_pic: abs(img), vod_content: desc,
                vod_play_from: froms.join('$$$'), vod_play_url: groups.join('$$$')
            }]
        });
    };
})();
`
};
