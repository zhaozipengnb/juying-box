// 收藏：影片收藏夹（KVStore 持久化），播放页/详情页红心与收藏页共用。
import { KVStore } from './ConfigStore';
import { Movie } from 'common';

export interface FavoriteItem {
  siteKey: string;
  vodId: string;
  name: string;
  pic: string;
  remark: string;
  typeName: string;
  addedAt: number;
}

const KEY = 'okvideo_favorites';

@ObservedV2
export class Favorites {
  static instance: Favorites = new Favorites();
  private store: KVStore | null = null;
  @Trace items: FavoriteItem[] = [];

  attach(store: KVStore): void {
    this.store = store;
    this.load();
  }

  private load(): void {
    const raw = this.store?.getSync(KEY);
    if (raw === undefined || raw === '') { this.items = []; return; }
    try {
      const arr = JSON.parse(raw) as FavoriteItem[];
      if (Array.isArray(arr)) { this.items = arr; }
    } catch (e) { this.items = []; }
  }

  private persist(): void {
    this.store?.putSync(KEY, JSON.stringify(this.items));
  }

  isFav(siteKey: string, vodId: string): boolean {
    return this.items.some((x: FavoriteItem): boolean => x.siteKey === siteKey && x.vodId === vodId);
  }

  toggle(siteKey: string, m: Movie): boolean {
    const hit = this.isFav(siteKey, m.vodId);
    if (hit) {
      this.items = this.items.filter((x: FavoriteItem): boolean => !(x.siteKey === siteKey && x.vodId === m.vodId));
    } else {
      const it: FavoriteItem = {
        siteKey: siteKey, vodId: m.vodId, name: m.name, pic: m.pic,
        remark: m.remark, typeName: m.typeName, addedAt: Date.now()
      };
      this.items.unshift(it);
    }
    this.persist();
    return !hit;   // 返回 toggle 后状态
  }

  remove(siteKey: string, vodId: string): void {
    this.items = this.items.filter((x: FavoriteItem): boolean => !(x.siteKey === siteKey && x.vodId === vodId));
    this.persist();
  }
}
