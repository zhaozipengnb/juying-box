// 金牌影院（www.610pkea.com）采集源。
// 站点为 Next.js SPA，无苹果CMS 采集接口；数据出自主站前端调用的 mw-movie 服务
// （/api/mw-movie/anonymous/*，全部免登录），请求需带签名头：
//   sign = SHA1(MD5(「参数按 key 排序 k=v&…」+ &key=固定key&t=毫秒时间戳))
//   头：client-type/t/sign/deviceId/authorization（签名算法逆向自站点前端 JS）。
// 本应用 drpy 壳的运行时只认字符串选择器（一级/二级），无法表达按请求签名，
// 故借 预处理 钩子在 init 末尾把 __DRPY 的六个方法整体替换为命令式 API 实现
// （壳页面每次调用都从 globalThis.__DRPY 取方法，见 drpy_shell.html）。
// 选集地址编码为站点播放页 /vod/play/{vodId}/sid/{nid}：播放层（DrpyDriver.playContent）
// 起播前调本源的 play() 换取真实 m3u8 直链。
var rule = {
    title: '金牌影院',
    host: 'https://www.610pkea.com',
    class_name: '电影&电视剧&综艺&动漫&短剧',
    class_url: '1&2&3&4&88',
    searchable: 2,
    quickSearch: 0,
    filterable: 0,
    play_parse: false,
    预处理: `js:
(function () {
    var API = 'https://www.610pkea.com/api/mw-movie';
    var SIGN_KEY = 'cb808529bae6b6be45ecfab29a4889bc';
    var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    var D = globalThis.__DRPY;
    if (!D) { return; }  // 非 drpy_shell 宿主（本地调试）：不动方法，保留默认实现

    // deviceId：会话内稳定即可（壳的 local 为内存版 KV，重启后自然换新）
    var DEV = local.get('jpyy', 'deviceId', '');
    if (!DEV) {
        DEV = 'okv-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
        local.set('jpyy', 'deviceId', DEV);
    }

    // 签名请求：GET path + params → data（code!==200 抛错）
    function apiGet(path, params) {
        var t = String(Date.now());
        var keys = Object.keys(params).sort();
        var g = keys.map(function (k) { return k + '=' + params[k]; }).join('&');
        var h = (g ? g + '&' : '') + 'key=' + SIGN_KEY + '&t=' + t;
        var sign = CryptoJS.SHA1(CryptoJS.MD5(h).toString()).toString();
        var q = keys.map(function (k) {
            return encodeURIComponent(k) + '=' + encodeURIComponent(String(params[k]));
        }).join('&');
        var r = req(API + path + (q ? '?' + q : ''), {
            headers: {
                'User-Agent': UA,
                'Accept': 'application/json, text/plain, */*',
                'client-type': '1',
                't': t,
                'sign': sign,
                'authorization': '',
                'deviceId': DEV,
                'Referer': 'https://www.610pkea.com/',
                'Origin': 'https://www.610pkea.com'
            }
        });
        var j = {};
        try { j = JSON.parse(r.content || '{}'); } catch (e) { throw new Error('接口返回非JSON:' + path); }
        if (j.code !== 200) { throw new Error('接口' + j.code + ' ' + (j.msg || '') + ':' + path); }
        return j.data || {};
    }

    function toVod(it) {
        var rem = it.vodRemarks || (it.vodIsend === 1 ? '已完结' : (it.vodYear || ''));
        return {
            vod_id: String(it.vodId),
            vod_name: it.vodName || '',
            vod_pic: it.vodPic || '',
            vod_remarks: rem,
            type_name: (it.vodClass || '').split(',')[0]
        };
    }

    // 分类：顶级 type1（1电影 2电视剧 3综艺 4动漫 88短剧，与站点导航一致）
    D.home = function () {
        var names = ['电影', '电视剧', '综艺', '动漫', '短剧'];
        var ids = ['1', '2', '3', '4', '88'];
        var cs = [];
        for (var i = 0; i < ids.length; i++) { cs.push({ type_id: ids[i], type_name: names[i] }); }
        return JSON.stringify({ class: cs });
    };

    // 首页推荐：电影最新一页
    D.homeVod = function () {
        var d = apiGet('/anonymous/video/list', { pageNum: '1', pageSize: '24', type1: '1' });
        return JSON.stringify({ list: (d.list || []).map(toVod) });
    };

    D.category = function (tid, pg) {
        var page = parseInt(pg, 10) || 1;
        var d = apiGet('/anonymous/video/list', { pageNum: String(page), pageSize: '24', type1: String(tid) });
        return JSON.stringify({
            list: (d.list || []).map(toVod),
            page: d.pageNum || page,
            pagecount: d.totalPage || 1
        });
    };

    D.detail = function (ids) {
        var id = String(ids).split(',')[0].trim();
        var d = apiGet('/anonymous/video/detail', { id: id });
        var eps = d.episodeList || [];
        var segs = [];
        for (var i = 0; i < eps.length; i++) {
            var name = eps[i].name || ('第' + (eps[i].sort || i + 1) + '集');
            segs.push(name + '$https://www.610pkea.com/vod/play/' + d.vodId + '/sid/' + eps[i].nid);
        }
        if (!segs.length) { throw new Error('该影片无选集'); }
        return JSON.stringify({
            list: [{
                vod_id: String(d.vodId),
                vod_name: d.vodName || '',
                vod_pic: d.vodPic || '',
                vod_remarks: d.vodRemarks || '',
                type_name: d.typeName || '',
                vod_year: d.vodYear || '',
                vod_area: d.vodArea || '',
                vod_actor: d.vodActor || '',
                vod_director: d.vodDirector || '',
                vod_content: d.vodContent || '',
                vod_play_from: '金牌影院',
                vod_play_url: segs.join('#')
            }]
        });
    };

    // 起播解析：播放页地址 → episode/url 接口 → 取第一个可用直链（多清晰度默认最高）
    D.play = function (flag, id) {
        var m = String(id).match(/\\/vod\\/play\\/(\\d+)\\/sid\\/(\\d+)/);
        if (!m) { throw new Error('播放地址格式不符:' + id); }
        var d = apiGet('/anonymous/v2/video/episode/url', { clientType: '1', id: m[1], nid: m[2] });
        var ls = d.list || [];
        for (var i = 0; i < ls.length; i++) {
            if (ls[i].url && String(ls[i].url).indexOf('http') === 0) {
                return JSON.stringify({ url: ls[i].url, parse: 0, header: { 'User-Agent': UA } });
            }
        }
        throw new Error('未取到播放直链（可能需登录）');
    };

    D.search = function (wd, quick) {
        var d = apiGet('/anonymous/video/searchByWordPageable', { keyword: String(wd || ''), pageNum: '1', pageSize: '30' });
        return JSON.stringify({ list: (d.list || []).map(toVod) });
    };
})();
`
};
