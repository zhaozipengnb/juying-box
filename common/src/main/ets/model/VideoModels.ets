// 视频业务模型：CmsJsonApi（Task 7）与 UI 层依赖，字段签名以计划 Interfaces 块为准，不得改名。
export interface Movie { vodId: string; name: string; pic: string; remark: string; typeName: string; siteKey?: string; score?: string }
// siteKey：条目来源站 key（可选）。详情页跨源聚合时把该站排队列最首，最先出结果。
export interface Category { tid: string; name: string }
export interface HomeContent { categories: Category[]; items: Movie[] }
export interface Episode { name: string; url: string; parse?: string }   // parse='1':url 为网页地址,需嗅探真实流
export interface PlayLine { from: string; episodes: Episode[] }
export interface MovieDetail { movie: Movie; desc: string; year: string; actor: string; director: string; lines: PlayLine[] }
export interface PageResult { page: number; pageCount: number; items: Movie[] }
