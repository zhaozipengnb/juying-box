// 全局路由栈单例：避免跨组件层层传递 NavPathStack 的样板代码。
export class Nav {
  static stack: NavPathStack = new NavPathStack();
}
