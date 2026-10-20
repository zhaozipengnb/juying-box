/**
 * HlsAdFilterServer：本机回环 HTTP 服务，为「AI去广告」提供播放列表改写。
 *
 * 原理：AVPlayer 拉流时把播放列表地址换成 http://127.0.0.1:<port>/f/<b64>.m3u8，
 * 本服务收到请求后回源取原始 m3u8 → HlsAdFilter 去广告分块 + 片段地址绝对化 → 回给播放器；
 * 媒体片段本身不经过本服务（列表里写的是源站 CDN 绝对地址），由播放器直连，带宽零开销。
 * 仅监听 127.0.0.1，进程外不可达。
 */
import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { filterHlsPlaylist } from 'common';
import { httpFetch } from './HttpClient';

const TAG = 'OKV-ADF';
const PORT_BASE = 47650;
const PORT_TRIES = 10;
const CACHE_TTL_MS = 8000;   // 播放器 seek 时会重复拉列表，短缓存避免反复回源

// URL → base64url（URL 字符先转 UTF-8 字节再标准 base64，+ / → - _；'=' 合法保留）
function b64urlEncode(s: string): string {
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(s);
  return new util.Base64Helper().encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_');
}

// base64url → 原始 URL
function b64urlDecode(s: string): string {
  const std: string = s.replace(/-/g, '+').replace(/_/g, '/');
  const bytes: Uint8Array = new util.Base64Helper().decodeSync(std);
  return new util.TextDecoder('utf-8').decodeToString(bytes);
}

function statusText(code: number): string {
  if (code === 200) { return 'OK'; }
  if (code === 404) { return 'Not Found'; }
  if (code === 400) { return 'Bad Request'; }
  return 'Bad Gateway';
}

class AdFilterServer {
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private starting: Promise<string> | null = null;
  private cache: Map<string, string> = new Map();       // 上游地址 → 过滤后文本
  private cacheAt: Map<string, number> = new Map();     // 缓存时间

  // 本服务基址；未启动返回 ''
  baseUrl(): string {
    return this.port === 0 ? '' : 'http://127.0.0.1:' + this.port;
  }

  // 把上游 m3u8 地址包成本地代理地址（播放列表改写用）
  wrapUrl(upstream: string): string {
    return this.baseUrl() + '/f/' + b64urlEncode(upstream) + '.m3u8';
  }

  // 幂等启动：绑定成功返回基址，全部端口失败返回 ''（调用方回退直连）
  async ensureStarted(): Promise<string> {
    if (this.port !== 0) { return this.baseUrl(); }
    if (this.starting !== null) { return this.starting; }
    this.starting = this.doStart().finally(() => { this.starting = null; });
    return this.starting;
  }

  private async doStart(): Promise<string> {
    for (let p = PORT_BASE; p < PORT_BASE + PORT_TRIES; p++) {
      const s: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      const ok: boolean = await new Promise<boolean>((resolve: (v: boolean) => void) => {
        s.listen({ address: '127.0.0.1', port: p, family: 1 } as socket.NetAddress,
          (err: Object | undefined) => { resolve(err === null || err === undefined); });
      });
      if (ok) {
        this.server = s;
        this.port = p;
        this.wire(s);
        hilog.info(0x0000, TAG, 'listening %{public}d', p);
        return this.baseUrl();
      }
    }
    hilog.error(0x0000, TAG, 'no port available %{public}d..%{public}d', PORT_BASE, PORT_BASE + PORT_TRIES - 1);
    return '';
  }

  private wire(s: socket.TCPSocketServer): void {
    s.on('connect', (client: socket.TCPSocketConnection) => {
      client.on('message', (info: socket.SocketMessageInfo) => {
        this.handle(client, info).catch((_e: Object) => { /* 单连接失败不影响服务 */ });
      });
    });
  }

  private async handle(client: socket.TCPSocketConnection, info: socket.SocketMessageInfo): Promise<void> {
    let path: string = '';
    try {
      const reqText: string = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(info.message));
      const m: RegExpMatchArray | null = reqText.match(/GET (\S+) HTTP/);
      if (m !== null) { path = m[1]; }
    } catch (e) { /* 解码失败按 400 处理 */ }
    const mm: RegExpMatchArray | null = path.match(/^\/f\/([A-Za-z0-9_=-]+)\.m3u8/);
    if (mm === null) {
      hilog.error(0x0000, TAG, 'unroutable path %{public}s', path.substring(0, 80));
      await this.respond(client, 404, 'text/plain', 'not found');
      return;
    }
    const upstream: string = b64urlDecode(mm[1]);
    try {
      const body: string = await this.getPlaylist(upstream);
      hilog.info(0x0000, TAG, 'serve %{public}d B %{public}s', body.length, upstream.substring(0, 72));
      await this.respond(client, 200, 'application/vnd.apple.mpegurl', body);
    } catch (e) {
      hilog.error(0x0000, TAG, 'upstream fail %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      await this.respond(client, 502, 'text/plain', 'upstream error');
    }
  }

  // 回源取原始列表 → 过滤改写（带短缓存）
  private async getPlaylist(upstream: string): Promise<string> {
    const hit: string | undefined = this.cache.get(upstream);
    const at: number = this.cacheAt.get(upstream) ?? 0;
    if (hit !== undefined && Date.now() - at < CACHE_TTL_MS) { return hit; }
    const r = await httpFetch(upstream, {});
    if (r.status !== 200) { throw new Error('HTTP ' + r.status); }
    const filtered: string = filterHlsPlaylist(r.text(), upstream, (u: string): string => this.wrapUrl(u));
    this.cache.set(upstream, filtered);
    this.cacheAt.set(upstream, Date.now());
    return filtered;
  }

  private async respond(client: socket.TCPSocketConnection, code: number, ctype: string, bodyText: string): Promise<void> {
    const enc: util.TextEncoder = new util.TextEncoder();
    const body: Uint8Array = enc.encodeInto(bodyText);
    const head: string = 'HTTP/1.1 ' + code + ' ' + statusText(code)
      + '\r\nContent-Type: ' + ctype
      + '\r\nContent-Length: ' + body.length
      + '\r\nConnection: close\r\n\r\n';
    const hb: Uint8Array = enc.encodeInto(head);
    const buf: Uint8Array = new Uint8Array(hb.length + body.length);
    buf.set(hb, 0);
    buf.set(body, hb.length);
    try { await client.send({ data: buf.buffer }); } catch (e) { /* 对端已断开 */ }
    try { await client.close(); } catch (e) { /* 关闭失败忽略 */ }
  }
}

export const HlsAdFilterServer: AdFilterServer = new AdFilterServer();
