// 全局路由栈单例：避免跨组件层层传递 NavPathStack 的样板代码。
import { Episode } from 'common';

export class Nav {
  static stack: NavPathStack = new NavPathStack();
}

// 播放页跳转参数：DetailPage 组装，Task 8 PlayerPage 消费
export interface PlayerParam { ep: Episode; siteKey: string; movieName?: string }
