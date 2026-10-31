// AVPlayerEngine:AVPlayer 封装(替代 Video 组件)。
// Video 组件的 currentProgressRate 仅构造期生效、VideoController 无 setSpeed——
// 本封装直接操作 AVPlayer:真倍速(setSpeed)、循环(loop)、精准 seek、状态机回调。
// surface 经 XComponent(onLoad 回调取 surfaceId)注入;open 前未就绪则挂起待 surface。
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
const ETAG = 'OKV-AVP';

export type EngineState = 'idle' | 'prepared' | 'playing' | 'paused' | 'error';

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
  private surfaceId: string = '';
  private pendingUrl: string = '';     // surface 未就绪时挂起的打开请求
  private pendingAutoPlay: boolean = false;
  url: string = '';
  speed: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  loop: boolean = false;
  onTime?: (sec: number) => void;
  onState?: (s: EngineState) => void;
  onVideoSize?: (w: number, h: number) => void;
  onError?: (msg: string) => void;

  // XComponent onLoad 时注入 surface;有挂起的打开请求则继续
  setSurface(id: string): void {
    hilog.info(0x0000, ETAG, 'setSurface %{public}s pending=%{public}s', id, this.pendingUrl !== '' ? 'Y' : 'N');
    this.surfaceId = id;
    if (this.pendingUrl !== '') {
      // surface 后到:续跑挂起的 open(此时 player 尚未创建,open 内部会 createAVPlayer)
      const url = this.pendingUrl;
      const auto = this.pendingAutoPlay;
      this.pendingUrl = '';
      this.open(url, auto);
    }
  }

  // 打开地址:重建播放器(reset→设 url/surface/loop→prepare→按需 play)
  async open(url: string, autoPlay: boolean): Promise<void> {
    this.url = url;
    this.pendingUrl = '';
    if (this.surfaceId === '') {
      // surface 未就绪:挂起,等 setSurface 注入后再继续
      this.pendingUrl = url;
      this.pendingAutoPlay = autoPlay;
      return;
    }
    if (this.player === null) {
      hilog.info(0x0000, ETAG, 'createAVPlayer');
      this.player = await media.createAVPlayer();
      this.wire(this.player);
    } else {
      hilog.info(0x0000, ETAG, 'reset existing');
      await this.player.reset();
    }
    const p = this.player;
    p.url = url;
    p.loop = this.loop;
    p.surfaceId = this.surfaceId;
    p.setSpeed(this.speed);
    hilog.info(0x0000, ETAG, 'open url=%{public}s surface=%{public}s speed=%{public}d', url.substring(0, 60), this.surfaceId, this.speed);
    this.onState?.('idle');
    await p.prepare();
    hilog.info(0x0000, ETAG, 'prepared, dur=%{public}d', p.duration);
    this.onState?.('prepared');
    if (autoPlay) { await p.play(); hilog.info(0x0000, ETAG, 'play() done'); }
  }

  private wire(p: media.AVPlayer): void {
    p.on('timeUpdate', (timeMs: number): void => {
      this.onTime?.(Math.floor(timeMs / 1000));
    });
    p.on('stateChange', (state: string, reason: media.StateChangeReason): void => {
      hilog.info(0x0000, ETAG, 'state -> %{public}s', state);
      if (state === 'playing') { this.onState?.('playing'); }
      else if (state === 'paused') { this.onState?.('paused'); }
      else if (state === 'prepared') { this.onState?.('prepared'); }
    });
    p.on('videoSizeChange', (w: number, h: number): void => {
      this.onVideoSize?.(w, h);
    });
    p.on('error', (err: Object): void => {
      const msg = err instanceof Error ? err.message : JSON.stringify(err);
      hilog.error(0x0000, ETAG, 'AVP error %{public}s', msg);
      this.onState?.('error');
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

  // 真倍速(Video 组件做不到的能力)
  setSpeed(s: number): void {
    this.speed = speedEnum(s);
    this.player?.setSpeed(this.speed);
  }

  setLoop(v: boolean): void {
    this.loop = v;
    if (this.player !== null) { this.player.loop = v; }
  }

  async release(): Promise<void> {
    if (this.player !== null) {
      await this.player.release();
      this.player = null;
    }
  }
}
