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

// 下载任务条目:进度/状态标 @Trace——页面镜像数组持同一实例即可实时刷新进度
@ObservedV2
export class DownloadItem {
  id: string = '';             // 唯一 ID（URL 摘要）
  movieName: string = '';      // 影片名
  epName: string = '';         // 集名
  url: string = '';            // 下载地址
  localPath: string = '';      // 本地文件全路径
  @Trace progress: number = 0; // 0–100
  @Trace status: DownloadStatus = 'pending';
  totalSize: number = 0;       // 总字节
  downloadedSize: number = 0;  // 已下载字节
  siteKey: string = '';        // 来源站点
  // HLS 断点续传检查点:已完成分段数/总数(追加写入,续传从此分段继续)
  @Trace segDone: number = 0;
  @Trace segTotal: number = 0;
  // 实时网速(bytes/s,@Trace 让页面即时刷新;估算值,不持久化)
  @Trace speed: number = 0;
  private lastBytes: number = 0;   // 速度采样基准(上次已下字节)
  private lastTs: number = 0;      // 速度采样基准(上次时间戳)
  headers: Record<string, string> = {};  // 源站防盗链头(续传时复用,随任务持久化)
}

const KEY_DOWNLOADS = 'juying_downloads_json';
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

  // 启动下载。headers:源站防盗链头(站点 header + UA),mp4 透传给 agent、HLS 透传给分段拉取
  async startDownload(movieName: string, epName: string, url: string, siteKey: string,
    headers: Record<string, string> = {}): Promise<void> {
    if (!this.context) { return; }
    const context = this.context;   // 回调里用的上下文(编译器无法跨闭包跟踪非空)
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
      hilog.info(DOMAIN, 'OKV-DL', 'dir exists: %{public}s', dir);
    } catch (e) {
      hilog.info(DOMAIN, 'OKV-DL', 'dir missing, mkdir: %{public}s', dir);
      try {
        fs.mkdirSync(dir, true);
        hilog.info(DOMAIN, 'OKV-DL', 'mkdir ok');
      } catch (err) {
        hilog.error(DOMAIN, 'OKV-DL', 'mkdir fail: %{public}s', err instanceof Error ? err.message : String(err));
      }
    }
    const isHls = /\.m3u8($|\?)/i.test(url);
    const fileName = `${this.safeName(movieName)}_${this.safeName(epName)}.${isHls ? 'ts' : 'mp4'}`;
    const localPath = `${dir}/${fileName}`;

    const item: DownloadItem = new DownloadItem();
    item.id = id;
    item.movieName = movieName;
    item.epName = epName;
    item.url = url;
    item.localPath = localPath;
    item.siteKey = siteKey;
    item.headers = headers;
    this.items.push(item);
    this.save();

    try {
      if (/\.m3u8($|\?)/i.test(url) || (!isDirectMedia(url) && url.startsWith('http'))) {
        // HLS：拉播放列表 → 全部分段顺序拼接为 .ts（request.agent 只能下直链）；
        // 批量选集时多任务并发会互相抢带宽,限 2 路同时下载其余排队
        this.scheduleHls(item, headers);
        return;
      }
      const cfg: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url,
        // saveas 契约:不支持绝对沙箱路径!支持 './data/storage/…'(base 目录内)——
        // 本应用 filesDir 即 /data/storage/el2/base/…,加 '.' 前缀即合法形态
        saveas: '.' + localPath,
        gauge: true,
        overwrite: true,
        mode: request.agent.Mode.BACKGROUND,
        headers: headers as object,   // 防盗链源必须带源站 UA/Referer,默认头会被 CDN 掐断
      };
      const task = await request.agent.create(this.context, cfg);
      this.taskMap.set(id, task);
      this.updateStatus(id, 'downloading');

      // 网速估算:进度回调差分,按 item 上临时基准计算(回调周期约 1s,天然平滑)
      let lastBytes = 0;
      let lastTs = Date.now();
      task.on('progress', (progress: request.agent.Progress): void => {
        const processed = progress.processed;
        const now = Date.now();
        const dt = now - lastTs;
        if (dt > 500) {
          item.speed = (processed - lastBytes) * 1000 / dt;
          lastBytes = processed;
          lastTs = now;
        }
        this.updateProgress(id, 0, processed, 0);
      });
      task.on('completed', (): void => {
        item.speed = 0;
        let at = false;
        try { fs.accessSync(localPath); at = true; } catch (e) { }
        if (!at) {
          // 自愈:saveas 相对路径若被解释到 cacheDir(契约里相对路径归属 cache),
          // 按该形态探测并把文件搬到 localPath,保证播放按钮路径正确
          const alt = `${context.cacheDir}/data/storage/el2/base/haps/entry/files/downloads/${localPath.substring(localPath.lastIndexOf('/') + 1)}`;
          try {
            fs.accessSync(alt);
            fs.renameSync(alt, localPath);
            at = true;
            hilog.info(DOMAIN, 'OKV-DL', 'mp4 relocated from cache-alt to localPath');
          } catch (e) { }
        }
        hilog.info(DOMAIN, 'OKV-DL', 'mp4 completed, file at localPath=%{public}s', at ? 'yes' : 'NO(未找到,需排查)');
        this.updateProgress(id, 100, 0, 0);
        this.updateStatus(id, 'completed');
        this.taskMap.delete(id);
        this.save();
      });
      task.on('failed', (): void => {
        item.speed = 0;
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

  private scheduleHls(item: DownloadItem, headers: Record<string, string> = {}): void {
    if (this.activeHls >= this.maxHls) {
      this.hlsWaiting.push(item);
      return;
    }
    this.activeHls++;
    this.downloadHls(item, headers).then((): void => {
      this.activeHls--;
      // 取下一个可起跑的排队项:pending=排队未启动,downloading=断点续传排入的——
      // 跳过已删除的、以及 paused/failed/completed 的(后者由用户显式"继续"再起跑)
      let next = this.hlsWaiting.shift();
      while (next !== undefined && (this.items.indexOf(next) < 0 || (next.status !== 'pending' && next.status !== 'downloading'))) {
        next = this.hlsWaiting.shift();
      }
      if (next !== undefined) { this.scheduleHls(next, headers); }
    });
  }

  // HLS 下载：master 列表取首子列表；逐段拉取追加写入 .ts。进度按已下字节数估算。
  // 加密流(AES-128)一期不支持解密——拼出来也是乱码,明确失败提示。
  // 断点续传:segDone=已完成分段数,startSeg>0 时以 APPEND 从断点追加;
  // 暂停/清空/重启后可从检查点"继续",失败的整段任务也能续传不重头
  private async downloadHls(item: DownloadItem, headers: Record<string, string> = {}): Promise<void> {
    this.updateStatus(item.id, 'downloading');
    try {
      let listUrl = item.url;
      let text = (await httpFetch(listUrl, { headers: item.headers })).text();
      if (text.indexOf('#EXT-X-STREAM-INF') >= 0) {
        const sub = this.firstMediaLine(text);
        if (sub === '') { throw new Error('HLS 列表无可播地址'); }
        listUrl = resolveUrl(listUrl, sub);
        text = (await httpFetch(listUrl, { headers: item.headers })).text();
      }
      if (text.indexOf('#EXT-X-KEY:METHOD=AES-128') >= 0 || text.indexOf('#EXT-X-KEY:METHOD=SAMPLE-AES') >= 0) {
        throw new Error('该源为加密 HLS，暂不支持下载');
      }
      const segs: string[] = [];
      for (const raw of text.split(/\r?\n/)) {
        const t = raw.trim();
        if (t === '' || t.startsWith('#')) { continue; }
        segs.push(resolveUrl(listUrl, t));
      }
      if (segs.length === 0) { throw new Error('HLS 无分段'); }
      // fMP4 切片:EXT-X-MAP 的 init 段必须放在最前,拼接才是合法 mp4
      const mapMatch = text.match(/#EXT-X-MAP:URI="([^"]+)"/);
      if (mapMatch !== null) { segs.unshift(resolveUrl(listUrl, mapMatch[1])); }
      item.segTotal = segs.length;
      const startSeg = Math.min(item.segDone, segs.length);   // 断点:上次完成到第几段
      // 写入前重建目录(前面 accessSync 已确认存在,这里再兜底一次并落日志)
      try {
        fs.mkdirSync(item.localPath.substring(0, item.localPath.lastIndexOf('/')), true);
      } catch (err) { /* 已存在会抛 File exists,忽略 */ }
      // startSeg>0 = 续传:APPEND 追加;=0 = 全新:TRUNC 覆盖旧残片
      const mode = startSeg > 0
        ? (fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND)
        : (fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      let f: fs.File;
      try {
        f = fs.openSync(item.localPath, mode);
      } catch (err) {
        // 兜底:中文名文件在此设备上异常时改用纯 ASCII 文件名重试
        const asciiPath = item.localPath.substring(0, item.localPath.lastIndexOf('/') + 1) + 'dl_' + item.id + '.ts';
        hilog.error(DOMAIN, 'OKV-DL', 'open fail %{public}s, retry ascii: %{public}s', err instanceof Error ? err.message : String(err), asciiPath);
        f = fs.openSync(asciiPath, mode);
        item.localPath = asciiPath;   // 播放按钮按这个路径离线播放
      }
      let done = 0;
      let speedBase = done;          // 网速窗口起点(字节)
      let speedTs = Date.now();      // 网速窗口起点(毫秒)
      for (let i = startSeg; i < segs.length; i++) {
        // 暂停/清空/删除:中止写入,检查点已持久化,随时可"继续"
        if (this.items.indexOf(item) < 0 || item.status !== 'downloading') {
          fs.closeSync(f);
          item.speed = 0;
          this.save();
          return;
        }
        const seg = segs[i];
        const r = await httpFetch(seg, { headers: item.headers });
        const bytes = new Uint8Array(r.body);
        fs.writeSync(f.fd, bytes.buffer);
        done += bytes.length;
        item.segDone = i + 1;
        // 网速:滑动窗口 EMA,秒级平滑(分段越大越抖,半衰滤波足够看)
        const now = Date.now();
        const dt = now - speedTs;
        if (dt > 500) {
          const inst = (done - speedBase) * 1000 / dt;
          item.speed = item.speed > 0 ? item.speed * 0.5 + inst * 0.5 : inst;
          speedBase = done;
          speedTs = now;
        }
        this.updateProgress(item.id, Math.min(99, Math.floor((i + 1) * 100 / segs.length)), done, 0);
        if ((i + 1) % 20 === 0) { this.save(); }   // 断点节流持久化
      }
      item.segDone = segs.length;
      item.speed = 0;
      fs.closeSync(f);
      this.updateProgress(item.id, 100, done, done);
      this.updateStatus(item.id, 'completed');
      hilog.info(DOMAIN, 'OKV-DL', 'hls done %{public}d segs %{public}d bytes', segs.length, done);
    } catch (e) {
      item.speed = 0;
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
    const it = this.items.find((x: DownloadItem): boolean => x.id === id);
    if (it !== undefined && (/\.m3u8($|\?)/i.test(it.url) || (!isDirectMedia(it.url) && it.url.startsWith('http')))) {
      // HLS:从检查点分段继续追加(headers 随任务持久化),暂停/失败/重启后都能续
      it.status = 'downloading';
      this.save();
      this.scheduleHls(it, it.headers);
      return;
    }
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

  // 清空全部:停 agent 任务、清 HLS 队列与进行中循环(循环内检测到条目被移除即中止)
  removeAll(): void {
    this.hlsWaiting = [];
    this.taskMap.forEach((t: request.agent.Task): void => {
      try { t.stop(); } catch (e) { /* ignore */ }
    });
    this.taskMap.clear();
    this.items = [];
    this.save();
  }

  // 持久化
  private save(): void {
    if (!this.store) { return; }
    const arr = this.items.map((it: DownloadItem): Record<string, Object> => ({
      'id': it.id, 'movieName': it.movieName, 'epName': it.epName, 'url': it.url,
      'localPath': it.localPath, 'progress': it.progress, 'status': it.status,
      'totalSize': it.totalSize, 'downloadedSize': it.downloadedSize, 'siteKey': it.siteKey,
      'segDone': it.segDone, 'segTotal': it.segTotal, 'headers': it.headers,
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
        const it = new DownloadItem();
        it.id = r['id'] as string;
        it.movieName = r['movieName'] as string;
        it.epName = r['epName'] as string;
        it.url = r['url'] as string;
        it.localPath = r['localPath'] as string;
        it.progress = r['progress'] as number;
        it.status = r['status'] as DownloadStatus;
        it.totalSize = r['totalSize'] as number;
        it.downloadedSize = r['downloadedSize'] as number;
        it.siteKey = r['siteKey'] as string;
        it.segDone = r['segDone'] as number ?? 0;
        it.segTotal = r['segTotal'] as number ?? 0;
        const hdr = r['headers'];
        if (hdr !== undefined && hdr !== null) { it.headers = hdr as Record<string, string>; }
        return it;
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
