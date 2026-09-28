/**
 * SiteDriver：站点引擎统一接口（后续 SiteFactory 依赖此签名，不得改动）
 * 引擎通过注入 FetchText 获得网络能力，从而保持 common 纯逻辑、零 @ohos 依赖、可本地单测。
 */
import { HomeContent, PageResult, MovieDetail } from '../model/VideoModels';

// 文本拉取函数签名：url + 可选请求头，返回响应文本（由 entry 层的 httpFetch 包装实现）
export type FetchText = (url: string, headers?: Record<string, string>) => Promise<string>;

// 站点引擎接口：首页 / 分类列表 / 详情 / 搜索
export interface SiteDriver {
  getHomeContent(): Promise<HomeContent>;
  categoryContent(tid: string, pg: number): Promise<PageResult>;
  detailContent(ids: string[]): Promise<MovieDetail>;
  searchContent(key: string, quick: boolean): Promise<PageResult>;
}
