// 兄弟影视（brovod.com）2026-10 改版规则：feifei 风格主题
// 结构：/show/{Movies|TV|Shows|Anime|Snaps|Documentaries}--------{pg}---/ 列表；
//       /detail/{slug}-{id}/ 详情；/ss/{关键词}-------------/ 搜索；
//       详情 .anthology-tab（线路）+.anthology-list-box（选集）；
//       播放页 player_aaaa.url 为 emoji 混淆串 → play.brovod.com/JX 服务端解码
//       （key = sha256(小时边界秒 + 'cnmdhb')，dmkey/pbgjz 取自 play.brovod.com 会话页）。
var rule = {
    title: '兄弟影视',
    host: 'https://www.brovod.com',
    homeUrl: '/',
    url: '/show/fyclass--------fypage---/',
    searchUrl: '/ss/**-------------/',
    searchable: 2,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    class_name: '电影&剧集&综艺&动漫&短剧&纪录片',
    class_url: 'Movies&TV&Shows&Anime&Snaps&Documentaries',
    推荐: 'body&&.public-list-box;a&&title;img&&data-src;.public-list-prb&&Text;a&&href',
    一级: 'body&&.public-list-box;a&&title;img&&data-src;.public-list-prb&&Text;a&&href',
    二级: {
        title: '.slide-info-title&&Text',
        img: '.detail-pic&&img&&data-src',
        desc: [
            '.info-parameter&&li:eq(4)&&Text',
            '.info-parameter&&li:eq(5)&&Text',
            '.info-parameter&&li:eq(6)&&Text',
            '.info-parameter&&li:eq(3)&&Text'
        ],
        content: '#height_limit&&Text',
        tabs: '.anthology-tab&&a',
        tab_text: 'Text',
        lists: '.anthology-list-box:eq(#id)&&.anthology-list-play&&li',
        list_text: 'a&&Text',
        list_url: 'a&&href'
    },
    搜索: 'body&&.public-list-box;.thumb-txt&&a&&Text;img&&data-src;.public-list-prb&&Text;a&&href',
    play_parse: true,
    lazy: `var html = req(input).content;
var m = html.match(/player_aaaa\\s*=\\s*(\\{[\\s\\S]*?\\})\\s*[;<]/);
if (!m) { throw new Error('播放页无 player_aaaa'); }
var pd = JSON.parse(m[1]);
var enc = encodeURIComponent(pd.url);
var cfg = req('https://play.brovod.com/?url=' + enc + '&next=&title=v').content;
var dmkey = (cfg.match(/"dmkey":"([^"]*)"/) || ['', ''])[1];
var pbgjz = (cfg.match(/"pbgjz":"([^"]*)"/) || ['', ''])[1];
var hour = Math.floor(Date.now() / 1000 / 3600) * 3600;
var key = CryptoJS.SHA256(String(hour) + 'cnmdhb').toString();
var body = JSON.stringify({ url: enc, pbgjz: pbgjz, dmkey: dmkey, key: key });
var r = req('https://play.brovod.com/JX', {
    method: 'POST',
    body: body,
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': 'https://play.brovod.com/',
        'Origin': 'https://play.brovod.com',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
});
var j = JSON.parse(r.content);
if (!j.url || j.url.indexOf('lcap-static') >= 0) { throw new Error('解码失败：' + (j.msg || j.error_field || '未知')); }
input = { parse: 0, url: j.url, header: {} };`
};
