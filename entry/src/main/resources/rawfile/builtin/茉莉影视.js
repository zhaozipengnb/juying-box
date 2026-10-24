// 茉莉影视（www.dormirencasasrurales.com）采集源：飞飞CMS feifei 列表 + myui 详情混合模板。
// 分类 /movie/{tid}-{pg}.html；详情 /gaoqing/{id}.html；选集 /play/{id}-{线路}-{集}.html
// （播放页 HTML 内嵌 m3u8 直链，通用解析可提取）；搜索 /search.php?searchword=。
// 注意：站点部分详情页选集为空（内容薄站），此类影片详情会报无选集，属站点数据问题。
var rule = {
    title: '茉莉影视',
    host: 'https://www.dormirencasasrurales.com',
    homeUrl: '/',
    url: '/movie/fyclass-fypage.html',
    searchUrl: '/search.php?searchword=**',
    class_name: '国产剧&香港剧&台湾剧&欧美剧&韩国剧&日本剧&泰国剧&海外剧&精品短剧',
    class_url: '5&6&7&8&9&10&11&12&13',
    searchable: 1,
    quickSearch: 0,
    filterable: 0,
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    },
    推荐: 'body&&.fed-list-item;a&&title;a&&data-original;.fed-list-remarks&&Text;a&&href',
    一级: 'body&&.fed-list-item;a&&title;a&&data-original;.fed-list-remarks&&Text;a&&href',
    二级: {
        title: '.fed-deta-content&&h1&&Text',
        img: '.stui-content__thumb&&img&&data-original',
        tabs: '.nav-tabs&&li',
        tab_text: 'a&&Text',
        lists: '.myui-content__list:eq(#id)&&li',
        list_text: 'a&&Text',
        list_url: 'a&&href'
    },
    搜索: 'body&&.fed-list-item;a&&title;a&&data-original;.fed-list-remarks&&Text;a&&href',
    play_parse: false
};
