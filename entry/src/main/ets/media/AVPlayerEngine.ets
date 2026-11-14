// AVPlayerEngine:AVPlayer 封装(替代 Video 组件)。
// Video 组件的 currentProgressRate 仅构造期生效、VideoController 无 setSpeed——
// 本封装直接操作 AVPlayer:真倍速(setSpeed)、循环(loop)、精准 seek、状态机回调。
// 关键时序:set url 后状态异步跳 initialized → 此时才能设 surfaceId → prepare →
// prepared → 才能 setSpeed/loop → play。同步赋值会打在 idle 上被状态机拒绝。
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
const ETAG = 'OKV-AVP';

export type EngineState = 'idle' | 'initialized' | 'prepared' | 'playing' | 'paused' | 'error';

// 播放倍速数值 → AVPlayer 档位
export function speedEnum(s: number): media.PlaybackSpeed {
  if (s === 0.5) { return media.PlaybackSpeed.SPEED_FORWARD_0_50_X; }
  if (s === 0.75) { return media.PlaybackSpeed.SPEED_FORWARD_0_75_X; }
  if (s === 1.25) { return media.PlaybackSpeed.SPEED_FORWARD_1_25_X; }
  if (s === 1.5) { return media.PlaybackSpeed.SPEED_FORWARD_1_50_X; }
  if (s === 1.75) { return media.PlaybackSpeed.SPEED_FORWARD_1_75_X; }
  if (s === 2.0) { return media.PlaybackSpeed.SPEED_FORWARD_2_00_X; }
  if (s === 3.0) { return media.PlaybackSpeed.SPEED_FORWARD_3_00_X; }
  return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
}

export class AVPlayerEngine {
  private player: media.AVPlayer | null = null;
  isLive: boolean = false;                // 直播流:AVPlayer 不允许 setSpeed/setLoop(prepared 时调必抛)
  private surfaceId: string = '';
  private state: EngineState = 'idle';
  private pendingPlay: boolean = false;   // prepared 后是否自动播放
  private localFd: number = -1;           // 本地文件播放的 fd(播放完/换址时关闭)
  url: string = '';
  speed: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  loop: boolean = false;
  onTime?: (sec: number) => void;
  onState?: (s: EngineState) => void;
  onVideoSize?: (w: number, h: number) => void;
  onError?: (msg: string) => void;

  // XComponent onLoad 时注入 surface;若 open 已先行(url 已设),补设并继续
  setSurface(id: string): void {
    this.surfaceId = id;
    if (this.player !== null && this.state === 'initialized') {
      this.player.surfaceId = id;
    }
  }

  // 打开地址:设 url → 状态机异步走到 initialized → 设 surface → prepare →
  // prepared → 设倍速/循环 → 按 pendingPlay 自动播放
  async open(url: string, autoPlay: boolean): Promise<void> {
    this.url = url;
    this.pendingPlay = autoPlay;
    // 换址前关掉上一个本地文件的 fd(调用方负责 fd 生命周期)
    if (this.localFd >= 0) {
      try { fs.closeSync(this.localFd); } catch (e) { /* ignore */ }
      this.localFd = -1;
    }
    if (this.player === null) {
      hilog.info(0x0000, ETAG, 'createAVPlayer');
      this.player = await media.createAVPlayer();
      this.wire(this.player);
    } else {
      await this.player.reset();   // → idle
    }
    this.state = 'idle';
    if (url.startsWith('file://')) {
      // 本地已下载文件:走 fd 媒体源(WithUrl 只认网络地址,file:// 会永远停在 idle 黑屏)
      const path = url.substring('file://'.length);
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const st = fs.statSync(path);
      this.localFd = f.fd;
      hilog.info(0x0000, ETAG, 'local file %{public}s fd=%{public}d size=%{public}lld', path, f.fd, Number(st.size));
      const ms = media.createMediaSourceWithFd({ fd: f.fd, offset: 0, length: st.size });
      if (ms === undefined) { throw new Error('本地媒体源创建失败'); }
      await this.player.setMediaSource(ms);
      this.onState?.('idle');
      return;
    }
    // 统一走带 UA 的 MediaSource:部分 CDN 按客户端 UA 拒绝媒体栈默认请求
    // (实测 didibo2 对 curl 类 UA 回 403/空响应),显式 okhttp UA 即放行
    const ms = media.createMediaSourceWithUrl(url, { 'User-Agent': 'okhttp/4.10.0' });
    await this.player.setMediaSource(ms);   // 触发异步 initialized → 见 wire
    this.onState?.('idle');
  }

  private wire(p: media.AVPlayer): void {
    p.on('stateChange', (state: string, _reason: media.StateChangeReason): void => {
      hilog.info(0x0000, ETAG, 'state -> %{public}s', state);
      if (state === 'initialized') {
        // 此时才允许设 surfaceId
        if (this.surfaceId !== '') { p.surfaceId = this.surfaceId; }
        p.prepare();
      } else if (state === 'prepared') {
        this.state = 'prepared';
        if (!this.isLive) {
          p.setSpeed(this.speed);   // prepared 状态才允许 setSpeed;直播流不支持,调了直接 error
          p.loop = this.loop;
        }
        this.onState?.('prepared');
        if (this.pendingPlay) {
          this.pendingPlay = false;
          p.play();
        }
      } else if (state === 'playing') {
        this.state = 'playing';
        this.onState?.('playing');
      } else if (state === 'paused') {
        this.state = 'paused';
        this.onState?.('paused');
      }
    });
    p.on('timeUpdate', (timeMs: number): void => {
      this.onTime?.(Math.floor(timeMs / 1000));
    });
    p.on('videoSizeChange', (w: number, h: number): void => {
      this.onVideoSize?.(w, h);
    });
    p.on('error', (err: Object): void => {
      const msg = err instanceof Error ? err.message : JSON.stringify(err);
      hilog.error(0x0000, ETAG, 'AVP error %{public}s', msg);
      this.state = 'error';
      this.onError?.(msg);
    });
  }

  get durationSec(): number {
    return this.player === null ? 0 : this.player.duration / 1000;
  }

  play(): void {
    this.player?.play();
  }

  pause(): void {
    this.player?.pause();
  }

  stop(): void {
    this.player?.stop();
  }

  seek(sec: number): void {
    this.player?.seek(Math.max(0, Math.floor(sec * 1000)));
  }

  // 真倍速(prepared/playing/paused 下合法;idle 只存值,prepared 回调统一应用)
  setSpeed(s: number): void {
    const e = speedEnum(s);
    if (this.player !== null && (this.state === 'prepared' || this.state === 'playing' || this.state === 'paused')) {
      this.player.setSpeed(e);
    }
    this.speed = e;
  }

  setLoop(v: boolean): void {
    if (this.isLive) { return; }   // 直播流不支持循环
    this.loop = v;
    if (this.player !== null && (this.state === 'prepared' || this.state === 'playing' || this.state === 'paused')) {
      this.player.loop = v;
    }
  }

  async release(): Promise<void> {
    if (this.player !== null) {
      await this.player.release();
      this.player = null;
      this.state = 'idle';
    }
    if (this.localFd >= 0) {
      try { fs.closeSync(this.localFd); } catch (e) { /* ignore */ }
      this.localFd = -1;
    }
  }
}
