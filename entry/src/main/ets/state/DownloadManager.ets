// 内置下载管理器：基于 @ohos.request.agent 后台下载，支持进度/暂停/恢复/删除。
// 持久化到 preferences，应用重启后恢复列表（已完成的可直接播放，下载中的需手动恢复）。
import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { KVStore } from './ConfigStore';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { httpFetch } from '../net/HttpClient';
import { resolveUrl, isDirectMedia } from 'common';

export type DownloadStatus = 'pending' | 'downloading' | 'paused' | 'completed' | 'failed';

export interface DownloadItem {
  id: string;             // 唯一 ID（URL 摘要）
  movieName: string;      // 影片名
  epName: string;         // 集名
  url: string;            // 下载地址
  localPath: string;      // 本地文件全路径
  progress: number;       // 0–100
  status: DownloadStatus;
  totalSize: number;      // 总字节
  downloadedSize: number; // 已下载字节
  siteKey: string;        // 来源站点
}

const KEY_DOWNLOADS = 'okvideo_downloads_json';
const DOMAIN = 0x0001;

@ObservedV2
export class DownloadManager {
  static instance: DownloadManager = new DownloadManager();

  @Trace items: DownloadItem[] = [];
  private context: common.UIAbilityContext | null = null;
  private store: KVStore | null = null;
  private taskMap: Map<string, request.agent.Task> = new Map();

  // EntryAbility 装配：注入 context + 持久化
  attach(context: common.UIAbilityContext, store: KVStore): void {
    this.context = context;
    this.store = store;
    this.load();
  }

  // URL 摘要作为唯一 ID（简单 djb2 哈希）
  private makeId(url: string): string {
    let hash = 5381;
    for (let i = 0; i < url.length; i++) {
      hash = ((hash << 5) + hash) + url.charCodeAt(i);
      hash = hash & 0x7FFFFFFF;
    }
    return hash.toString(16);
  }

  // 文件名安全化
  private safeName(s: string): string {
    return s.replace(/[\\/:*?"<>|]/g, '_').trim() || 'unknown';
  }

  isDownloading(url: string): boolean {
    const id = this.makeId(url);
    return this.items.some((it: DownloadItem): boolean => it.id === id && it.status !== 'failed');
  }

  getByUrl(url: string): DownloadItem | undefined {
    const id = this.makeId(url);
    return this.items.find((it: DownloadItem): boolean => it.id === id);
  }

  // 按影片+集名查任务(下载面板标记各集状态用:选中时还未解析出直链,只能按名字匹配)
  findByEp(movieName: string, epName: string): DownloadItem | undefined {
    return this.items.find((it: DownloadItem): boolean => it.movieName === movieName && it.epName === epName);
  }

  // 启动下载
  async startDownload(movieName: string, epName: string, url: string, siteKey: string): Promise<void> {
    if (!this.context) { return; }
    const id = this.makeId(url);
    const existIdx = this.items.findIndex((it: DownloadItem): boolean => it.id === id);
    if (existIdx >= 0) {
      if (this.items[existIdx].status !== 'failed') { return; }   // 在队列/已完成的不重复
      this.items.splice(existIdx, 1);                             // 失败任务允许重建重下
    }

    const dir = `${this.context.filesDir}/downloads`;
    // 首次下载时目录不存在,request.agent 与 HLS 建文件都会失败
    try {
      fs.accessSync(dir);
    } catch (e) {
      try { fs.mkdirSync(dir, true); } catch (err) { }
    }
    const isHls = /\.m3u8($|\?)/i.test(url);
    const fileName = `${this.safeName(movieName)}_${this.safeName(epName)}.${isHls ? 'ts' : 'mp4'}`;
    const localPath = `${dir}/${fileName}`;

    const item: DownloadItem = {
      id, movieName, epName, url, localPath,
      progress: 0, status: 'pending', totalSize: 0, downloadedSize: 0, siteKey,
    };
    this.items.push(item);
    this.save();

    try {
      if (/\.m3u8($|\?)/i.test(url) || (!isDirectMedia(url) && url.startsWith('http'))) {
        // HLS：拉播放列表 → 全部分段顺序拼接为 .ts（request.agent 只能下直链）；
        // 批量选集时多任务并发会互相抢带宽,限 2 路同时下载其余排队
        this.scheduleHls(item);
        return;
      }
      const cfg: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url,
        saveas: localPath,
        gauge: true,
        overwrite: true,
        mode: request.agent.Mode.BACKGROUND,
      };
      const task = await request.agent.create(this.context, cfg);
      this.taskMap.set(id, task);
      this.updateStatus(id, 'downloading');

      task.on('progress', (progress: request.agent.Progress): void => {
        const processed = progress.processed;
        this.updateProgress(id, 0, processed, 0);
      });
      task.on('completed', (): void => {
        this.updateProgress(id, 100, 0, 0);
        this.updateStatus(id, 'completed');
        this.taskMap.delete(id);
        this.save();
      });
      task.on('failed', (): void => {
        this.updateStatus(id, 'failed');
        this.taskMap.delete(id);
        this.save();
      });
    } catch (e) {
      hilog.error(DOMAIN, 'dl', 'create failed: %{public}s', `${e}`);
      this.updateStatus(id, 'failed');
      this.save();
    }
  }

  // HLS 并发闸:最多 2 路同时拼接,完成后从队列取下一个(HLS 是纯 ArkTS 循环,无并发闸会全量并发)
  private activeHls: number = 0;
  private readonly maxHls: number = 2;
  private hlsWaiting: DownloadItem[] = [];

  private scheduleHls(item: DownloadItem): void {
    if (this.activeHls >= this.maxHls) {
      this.hlsWaiting.push(item);
      return;
    }
    this.activeHls++;
    this.downloadHls(item).then((): void => {
      this.activeHls--;
      const next = this.hlsWaiting.shift();
      if (next !== undefined) { this.scheduleHls(next); }
    });
  }

  // HLS 下载：master 列表取首子列表；逐段拉取追加写入 .ts。进度按已下字节数估算。
  private async downloadHls(item: DownloadItem): Promise<void> {
    this.updateStatus(item.id, 'downloading');
    try {
      let listUrl = item.url;
      let text = (await httpFetch(listUrl, {})).text();
      if (text.indexOf('#EXT-X-STREAM-INF') >= 0) {
        const sub = this.firstMediaLine(text);
        if (sub === '') { throw new Error('HLS 列表无可播地址'); }
        listUrl = resolveUrl(listUrl, sub);
        text = (await httpFetch(listUrl, {})).text();
      }
      const segs: string[] = [];
      for (const raw of text.split(/\r?\n/)) {
        const t = raw.trim();
        if (t === '' || t.startsWith('#')) { continue; }
        segs.push(resolveUrl(listUrl, t));
      }
      if (segs.length === 0) { throw new Error('HLS 无分段'); }
      const f = fs.openSync(item.localPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      let done = 0;
      for (let i = 0; i < segs.length; i++) {
        const seg = segs[i];
        const r = await httpFetch(seg, {});
        const bytes = new Uint8Array(r.body);
        fs.writeSync(f.fd, bytes.buffer);
        done += bytes.length;
        this.updateProgress(item.id, Math.min(99, Math.floor((i + 1) * 100 / segs.length)), done, 0);
      }
      fs.closeSync(f);
      this.updateProgress(item.id, 100, done, done);
      this.updateStatus(item.id, 'completed');
      hilog.info(DOMAIN, 'OKV-DL', 'hls done %{public}d segs %{public}d bytes', segs.length, done);
    } catch (e) {
      this.updateStatus(item.id, 'failed');
      hilog.error(DOMAIN, 'OKV-DL', 'hls fail %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  // 播放列表第一个非注释行（master 取子列表用）
  private firstMediaLine(text: string): string {
    for (const raw of text.split(/\r?\n/)) {
      const t = raw.trim();
      if (t !== '' && !t.startsWith('#')) { return t; }
    }
    return '';
  }

  async pause(id: string): Promise<void> {
    const task = this.taskMap.get(id);
    if (task) {
      try { await task.pause(); } catch (e) { /* ignore */ }
    }
    this.updateStatus(id, 'paused');
    this.save();
  }

  async resume(id: string): Promise<void> {
    const task = this.taskMap.get(id);
    if (task) {
      try { await task.resume(); this.updateStatus(id, 'downloading'); } catch (e) { /* ignore */ }
    }
    this.save();
  }

  async remove(id: string): Promise<void> {
    const task = this.taskMap.get(id);
    if (task) {
      try { await task.stop(); } catch (e) { /* ignore */ }
      this.taskMap.delete(id);
    }
    this.items = this.items.filter((it: DownloadItem): boolean => it.id !== id);
    this.save();
  }

  // 持久化
  private save(): void {
    if (!this.store) { return; }
    const arr = this.items.map((it: DownloadItem): Record<string, Object> => ({
      'id': it.id, 'movieName': it.movieName, 'epName': it.epName, 'url': it.url,
      'localPath': it.localPath, 'progress': it.progress, 'status': it.status,
      'totalSize': it.totalSize, 'downloadedSize': it.downloadedSize, 'siteKey': it.siteKey,
    }));
    this.store.putSync(KEY_DOWNLOADS, JSON.stringify(arr));
  }

  load(): void {
    if (!this.store) { return; }
    const raw = this.store.getSync(KEY_DOWNLOADS);
    if (raw === undefined || raw === '') { return; }
    try {
      const arr = JSON.parse(raw) as Object[];
      this.items = arr.map((o: Object): DownloadItem => {
        const r = o as Record<string, Object>;
        const st = r['status'] as DownloadStatus;
        return {
          id: r['id'] as string, movieName: r['movieName'] as string, epName: r['epName'] as string,
          url: r['url'] as string, localPath: r['localPath'] as string,
          progress: r['progress'] as number, status: st,
          totalSize: r['totalSize'] as number, downloadedSize: r['downloadedSize'] as number,
          siteKey: r['siteKey'] as string,
        };
      });
      // 进程重启后 taskMap 丢失:HLS 拼接循环无法续传,mp4 任务句柄也要重新关联——
      // 统一把进行中/暂停的任务标为失败,可在面板或下载页重新发起
      this.items.forEach((it: DownloadItem): void => {
        if (it.status === 'downloading' || it.status === 'pending' || it.status === 'paused') {
          it.status = 'failed';
        }
      });
    } catch (e) { /* ignore corrupt data */ }
  }

  // 内部更新
  private updateStatus(id: string, status: DownloadStatus): void {
    const it = this.items.find((x: DownloadItem): boolean => x.id === id);
    if (it) { it.status = status; }
  }

  private updateProgress(id: string, pct: number, downloaded: number, total: number): void {
    const it = this.items.find((x: DownloadItem): boolean => x.id === id);
    if (it) {
      it.progress = pct;
      it.downloadedSize = downloaded;
      if (total > 0) { it.totalSize = total; }
    }
  }
}
