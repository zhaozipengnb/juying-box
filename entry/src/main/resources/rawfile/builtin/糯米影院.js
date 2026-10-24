// 糯米影院（www.fatgaytube.com）采集源：苹果CMS mxone 列表 + myui 详情混合模板，SSR 静态页。
// 分类 /nm/{tid}-{pg}.html；详情 /nuomi/{id}.html（多线路 #playlistN 页签）；选集
// /play/{id}-{线路}-{集}.html（播放页 HTML 内嵌 m3u8 直链，通用解析可提取）。
// 搜索接口 503，searchable 关闭。
var rule = {
    title: '糯米影院',
    host: 'https://www.fatgaytube.com',
    homeUrl: '/',
    url: '/nm/fyclass-fypage.html',
    class_name: '电影&电视剧&综艺&动漫',
    class_url: '1&2&3&4',
    searchable: 0,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    推荐: 'body&&.module-item;a&&title;img&&data-src;.module-item-text&&Text;a&&href',
    一级: 'body&&.module-item;a&&title;img&&data-src;.module-item-text&&Text;a&&href',
    二级: {
        title: 'h1&&Text',
        img: '.module-item-pic&&img&&data-src',
        tabs: '.nav-tabs&&li',
        tab_text: 'a&&Text',
        lists: '.myui-content__list:eq(#id)&&li',
        list_text: 'a&&Text',
        list_url: 'a&&href'
    },
    play_parse: false
};
