/**
 * DrpyCorsProxyServer：drpy 壳 Worker 的跨源请求代理（本机回环）。
 *
 * drpy 壳页面是 resource://rawfile（不透明 origin=null），Worker 内 XHR 访问外站 API 时，
 * 带自定义签名头（sign/t 等）会触发 CORS 预检，公网站点几乎不会回 ACAO 头而被拦
 * （现象：req failed: NetworkError）。本服务提供 /cors/<绝对URL> 直通代理：
 *   OPTIONS 一律 204 + Access-Control-Allow-Origin:* 放行预检；
 *   GET/POST 原样回源（应用侧 httpFetch 无 CORS 概念），应答附加 ACAO 头回给 Worker。
 * 上行头逐跳字段（host/connection/content-length/origin 等）剔除后转发，UA 缺省补浏览器 UA。
 * 请求体假定单包到达（与 HlsAdFilterServer 同款假设；drpy 请求均为小包）。
 * 仅监听 127.0.0.1，进程外不可达。
 */
import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpFetch } from './HttpClient';

const TAG = 'OKV-DCP';
const PORT_BASE = 47670;
const PORT_TRIES = 10;
const BROWSER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
// 预检放行头：按需补充（Chromium 会带上实际要发的自定义头名单）
const CORS_HEADERS = 'Access-Control-Allow-Origin: *'
  + '\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS'
  + '\r\nAccess-Control-Allow-Headers: *'
  + '\r\nAccess-Control-Max-Age: 600';

// 不转发到上游的头：逐跳字段 + 会破坏回源的寻址头（host 由 httpFetch 按目标重写）
const HOP_HEADERS: string[] = ['host', 'connection', 'content-length', 'accept-encoding', 'origin'];

class CorsProxyServer {
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private starting: Promise<string> | null = null;

  baseUrl(): string {
    return this.port === 0 ? '' : 'http://127.0.0.1:' + this.port;
  }

  // 幂等启动：成功返回基址，全部端口失败返回 ''（调用方回落直连 XHR）
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
    hilog.error(0x0502, TAG, 'no port available %{public}d..%{public}d', PORT_BASE, PORT_BASE + PORT_TRIES - 1);
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
    let method: string = 'GET';
    let path: string = '';
    let body: string = '';
    const headers: Record<string, string> = {};
    try {
      const text: string = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(info.message));
      const split: number = text.indexOf('\r\n\r\n');
      const headPart: string = split >= 0 ? text.substring(0, split) : text;
      body = split >= 0 ? text.substring(split + 4) : '';
      const lines: string[] = headPart.split('\r\n');
      const rl: string[] = lines[0].split(' ');
      method = rl[0] ?? 'GET';
      path = rl[1] ?? '';
      for (let i = 1; i < lines.length; i++) {
        const ci: number = lines[i].indexOf(':');
        if (ci > 0) { headers[lines[i].substring(0, ci).trim().toLowerCase()] = lines[i].substring(ci + 1).trim(); }
      }
    } catch (e) { /* 解析失败按 400 处理 */ }

    if (method === 'OPTIONS') {
      await this.respondRaw(client, 204, 'text/plain', new Uint8Array(0));
      return;
    }
    if (!path.startsWith('/cors/')) {
      await this.respondRaw(client, 404, 'text/plain', this.bytes('not found'));
      return;
    }
    const target: string = path.substring('/cors/'.length);
    if (!/^https?:\/\//i.test(target)) {
      await this.respondRaw(client, 400, 'text/plain', this.bytes('bad target'));
      return;
    }

    const fwd: Record<string, string> = {};
    for (const k of Object.keys(headers)) {
      if (HOP_HEADERS.indexOf(k) >= 0) { continue; }
      fwd[k] = headers[k];
    }
    if (fwd['user-agent'] === undefined) { fwd['user-agent'] = BROWSER_UA; }
    fwd['accept-encoding'] = 'identity';
    try {
      const r = await httpFetch(target, { method, headers: fwd });
      const ctype: string = r.headers['content-type'] ?? 'application/octet-stream';
      hilog.info(0x0000, TAG, 'proxy %{public}s -> %{public}d %{public}dB', target.substring(0, 90), r.status, r.body.byteLength);
      await this.respondRaw(client, r.status, ctype, new Uint8Array(r.body));
    } catch (e) {
      hilog.error(0x0502, TAG, 'upstream fail %{public}s %{public}s', target.substring(0, 90),
        e instanceof Error ? e.message : JSON.stringify(e));
      await this.respondRaw(client, 502, 'text/plain', this.bytes('upstream error'));
    }
  }

  private bytes(s: string): Uint8Array {
    return new util.TextEncoder().encodeInto(s);
  }

  // 统一应答：所有响应都带 CORS 放行头（204 预检应答也走这里）
  private async respondRaw(client: socket.TCPSocketConnection, code: number, ctype: string, body: Uint8Array): Promise<void> {
    const statusLine: string = code === 200 ? 'OK' : code === 204 ? 'No Content' : code === 400 ? 'Bad Request'
      : code === 404 ? 'Not Found' : 'Bad Gateway';
    const head: string = 'HTTP/1.1 ' + code + ' ' + statusLine
      + '\r\nContent-Type: ' + ctype
      + '\r\nContent-Length: ' + body.length
      + '\r\n' + CORS_HEADERS
      + '\r\nConnection: close\r\n\r\n';
    const hb: Uint8Array = this.bytes(head);
    const buf: Uint8Array = new Uint8Array(hb.length + body.length);
    buf.set(hb, 0);
    buf.set(body, hb.length);
    try { await client.send({ data: buf.buffer }); } catch (e) { /* 对端已断开 */ }
    try { await client.close(); } catch (e) { /* 关闭失败忽略 */ }
  }
}

export const DrpyCorsProxy: CorsProxyServer = new CorsProxyServer();
