// 全局路由栈单例：避免跨组件层层传递 NavPathStack 的样板代码。
import { Episode, PlayLine, MovieDetail } from 'common';

export class Nav {
  static stack: NavPathStack = new NavPathStack();
}

// 播放页跳转参数：DetailPage 组装，PlayerPage 消费
// lines/lineIdx/epIdx 用于播放页内线路轮循与剧集切换
export interface PlayerParam {
  ep: Episode;
  siteKey: string;
  siteName?: string;
  movieName?: string;
  detail?: MovieDetail;   // 完整详情（desc/year/actor/director 等）
  lines?: PlayLine[];   // 当前源的全部播放线路
  lineIdx?: number;     // 点击的线路索引
  epIdx?: number;       // 点击的剧集索引
  channelUrls?: string[]; // 直播多线路：当前频道的备选地址（>1 时播放页显示线路切换）
}
