// 播放历史：断点续播 + 观看记录（KVStore 持久化）。
// 每部影片一条（按 siteKey+vodId 去重），记录最新一集与播放进度；同一集续播 seek，
// 看完下一集时顺带记录"看到第几集"。无痕模式下不写入。
import { KVStore } from './ConfigStore';
import { Episode, Movie } from 'common';

export interface PlayRecord {
  siteKey: string;
  vodId: string;
  movieName: string;
  pic: string;
  remark: string;
  epName: string;
  epUrl: string;       // 续播 seek 判据：同集地址即续播
  lineIdx: number;
  epIdx: number;
  positionSec: number; // 断点（秒）；>= duration-10 视为看完，续播从头
  durationSec: number;
  updatedAt: number;
}

const KEY = 'juying_play_history';
const MAX = 100;

@ObservedV2
export class PlayHistory {
  static instance: PlayHistory = new PlayHistory();
  private store: KVStore | null = null;
  @Trace records: PlayRecord[] = [];

  attach(store: KVStore): void {
    this.store = store;
    this.load();
  }

  private load(): void {
    const raw = this.store?.getSync(KEY);
    if (raw === undefined || raw === '') { this.records = []; return; }
    try {
      const arr = JSON.parse(raw) as PlayRecord[];
      if (Array.isArray(arr)) { this.records = arr; }
    } catch (e) { this.records = []; }
  }

  private persist(): void {
    this.store?.putSync(KEY, JSON.stringify(this.records.slice(0, MAX)));
  }

  // 播放中记录进度（调用方节流）；duration<=0 时保持旧值
  update(siteKey: string, movie: Movie, ep: Episode, lineIdx: number, epIdx: number,
    positionSec: number, durationSec: number): void {
    const id = siteKey + '|' + movie.vodId;
    let r = this.records.find((x: PlayRecord): boolean => x.siteKey + '|' + x.vodId === id);
    if (r === undefined) {
      r = {
        siteKey: siteKey, vodId: movie.vodId, movieName: movie.name, pic: movie.pic,
        remark: movie.remark, epName: ep.name, epUrl: ep.url, lineIdx: lineIdx, epIdx: epIdx,
        positionSec: positionSec, durationSec: durationSec, updatedAt: Date.now()
      };
      this.records.unshift(r);
    } else {
      r.movieName = movie.name;
      r.pic = movie.pic;
      r.remark = movie.remark;
      r.epName = ep.name;
      r.epUrl = ep.url;
      r.lineIdx = lineIdx;
      r.epIdx = epIdx;
      r.positionSec = positionSec;
      if (durationSec > 0) { r.durationSec = durationSec; }
      r.updatedAt = Date.now();
      // 提到最前
      this.records = this.records.filter((x: PlayRecord): boolean => x !== r);
      this.records.unshift(r);
    }
    this.persist();
  }

  // 取断点：同集地址返回续播秒数，否则 0（看完的不续）
  resumePosition(siteKey: string, vodId: string, epUrl: string): number {
    const r = this.records.find((x: PlayRecord): boolean =>
      x.siteKey === siteKey && x.vodId === vodId && x.epUrl === epUrl);
    if (r === undefined) { return 0; }
    if (r.durationSec > 0 && r.positionSec >= r.durationSec - 10) { return 0; }  // 已看完
    return r.positionSec > 5 ? r.positionSec : 0;
  }

  // 集名中的集号("第03集"/"EP3"→3;无名内数字返回 -1)
  private epNumberOf(name: string): number {
    const m = name.match(/\d+/);
    return m === null ? -1 : parseInt(m[0]);
  }

  // 跨源断点:换源/换线路后 siteKey/vodId/epUrl 全变,resumePosition 必然落空——
  // 按片名+集号(集名无数字则按集名/集序)在全部记录里找最近一条,让换源也能续播
  resumePositionByName(movieName: string, epName: string, epIdx: number): number {
    const num = this.epNumberOf(epName);
    let best: PlayRecord | undefined = undefined;
    for (const r of this.records) {
      if (r.movieName !== movieName) { continue; }
      const hit = num >= 0
        ? this.epNumberOf(r.epName) === num
        : (r.epName === epName || r.epIdx === epIdx);
      if (!hit) { continue; }
      if (best === undefined || r.updatedAt > best.updatedAt) { best = r; }
    }
    if (best === undefined) { return 0; }
    if (best.durationSec > 0 && best.positionSec >= best.durationSec - 10) { return 0; }  // 已看完
    return best.positionSec > 5 ? best.positionSec : 0;
  }

  // 详情页提示：上次看到第几集（无记录返回 ''）
  lastWatchLabel(siteKey: string, vodId: string): string {
    const r = this.records.find((x: PlayRecord): boolean => x.siteKey === siteKey && x.vodId === vodId);
    if (r === undefined) { return ''; }
    return '上次看到 ' + r.epName;
  }

  remove(siteKey: string, vodId: string): void {
    this.records = this.records.filter((x: PlayRecord): boolean => !(x.siteKey === siteKey && x.vodId === vodId));
    this.persist();
  }

  clear(): void {
    this.records = [];
    this.persist();
  }
}
