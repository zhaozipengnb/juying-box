// 茉莉影院（www.kangxindetection.com）采集源：苹果CMS ewave 模板（混淆 class 名），SSR 静态页。
// 分类 /vodtype/{tid}.html；分页 /vodshow/{tid}-----------{pg}.html；详情 /moli/{id}.html；
// 选集 /moliplay/{id}-{线路}-{集}.html（播放页 player_aaaa.url 内嵌 m3u8，通用解析可提取）。
// 分类 tid 为站点混淆串（OHHHHO 等），原样使用。搜索接口 403 拦截，searchable 关闭。
// 站点连通性不稳定（偶发 No route to host）。
var rule = {
    title: '茉莉影院',
    host: 'https://www.kangxindetection.com',
    homeUrl: '/',
    url: '/vodshow/fyclass-----------fypage.html',
    class_name: '电影&连续剧&综艺&动漫&短剧',
    class_url: 'OHHHHO&fHHHHO&kHHHHO&uHHHHO&wHHHHO',
    searchable: 0,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    推荐: 'body&&.video-item;a&&title;.item-pic&&data-original;.video-con-tit&&Text;a&&href',
    一级: 'body&&.video-item;a&&title;.item-pic&&data-original;.video-con-tit&&Text;a&&href',
    二级: {
        title: 'h1&&Text',
        img: '.video-info&&.item-pic&&data-original',
        tabs: '.ewave-tab',
        tab_text: 'Text',
        lists: '.playlist-slide:eq(#id)&&li',
        list_text: 'a&&Text',
        list_url: 'a&&href'
    },
    play_parse: false
};
