/**
 * SniffProxyServer：嗅探直链的本地回环代理(带防盗链 headers)。
 *
 * 背景：嗅探(parse:1)抓到的媒体直链常带 referer/UA 防盗链,SDK 26 的 AVPlayer
 * 不支持自定义 headers(裸播被 CDN 403/返回非媒体内容 → CONTAINER_ERR)。
 * 本代理:AVPlayer 播 http://127.0.0.1:<port>/h/<b64(headersJson)>/<b64(target)>,
 * 收到请求后带 headers 回源取内容原样回给播放器;m3u8 响应内的分片/密钥地址
 * 改写为同 headers 的代理地址(嵌套一层),分片也经代理带 headers 回源。
 * 仅监听 127.0.0.1,进程外不可达。
 */
import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpFetch } from './HttpClient';
import http from '@ohos.net.http';
import { resolveUrl } from 'common';

const TAG = 'OKV-SNP';
const PORT_BASE = 47690;
const PORT_TRIES = 10;
const BROWSER_UA = 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

function b64urlEncode(s: string): string {
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(s);
  return new util.Base64Helper().encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_');
}

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

class SniffProxyServer {
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private starting: Promise<string> | null = null;

  baseUrl(): string {
    return this.port === 0 ? '' : 'http://127.0.0.1:' + this.port;
  }

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
    hilog.error(0x0000, TAG, 'no port available');
    return '';
  }

  private wire(s: socket.TCPSocketServer): void {
    s.on('connect', (client: socket.TCPSocketConnection) => {
      client.on('message', (info: socket.SocketMessageInfo) => {
        this.handle(client, info).catch((_e: Object) => { /* 单连接失败不影响服务 */ });
      });
    });
  }

  // 包装:headers JSON + 目标地址 → 本地代理地址(扩展名保留,便于播放器识别)
  wrap(target: string, headersJson: string): string {
    return this.baseUrl() + '/h/' + b64urlEncode(headersJson) + '/' + b64urlEncode(target);
  }

  private async handle(client: socket.TCPSocketConnection, info: socket.SocketMessageInfo): Promise<void> {
    let path: string = '';
    try {
      const reqText: string = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(info.message));
      const m: RegExpMatchArray | null = reqText.match(/GET (\S+) HTTP/);
      if (m !== null) { path = m[1]; }
    } catch (e) { /* 解码失败按 400 处理 */ }
    const mm: RegExpMatchArray | null = path.match(/^\/h\/([A-Za-z0-9_=-]+)\/([A-Za-z0-9_=-]+?)(\.[a-zA-Z0-9]+)?(?:\?.*)?$/);
    if (mm === null) {
      await this.respond(client, 404, 'text/plain', 'not found');
      return;
    }
    let headers: Record<string, string> = {};
    try {
      headers = JSON.parse(b64urlDecode(mm[1])) as Record<string, string>;
    } catch (e) { /* 头解析失败按空处理 */ }
    const target: string = b64urlDecode(mm[2]);
    if (!/^https?:\/\//i.test(target)) {
      await this.respond(client, 400, 'text/plain', 'bad target');
      return;
    }
    const isM3u8: boolean = /\.m3u8($|\?)/i.test(target);
    try {
      if (isM3u8) {
        // 播放列表(小文件):整体取回 → 分片/密钥地址改写为同 headers 的代理地址
        const r = await httpFetch(target, { headers: headers, timeoutMs: 30000 });
        if (r.status !== 200) { await this.respond(client, r.status, 'text/plain', 'upstream ' + r.status); return; }
        // 按内容分类:头 7 字节 #EXTM3U → 播放列表(改写);否则视为媒体字节直传
        // (嗅探端点可能直出视频流,按 URL 后缀强判会损坏二进制 → CONTAINER_ERR)
        const buf: ArrayBuffer = r.body;
        const headStr: string = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf.slice(0, 7)));
        if (!headStr.startsWith('#EXTM3U')) {
          const ctype: string = r.headers['content-type'] ?? 'video/mp2t';
          hilog.info(0x0000, TAG, 'serve raw %{public}d B %{public}s ctype=%{public}s', buf.byteLength, target.substring(0, 60), ctype);
          await this.respondBytes(client, r.status, ctype, new Uint8Array(buf));
          return;
        }
        const body: string = this.rewriteM3u8(new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf)), target, headers);
        hilog.info(0x0000, TAG, 'serve m3u8 %{public}d B %{public}s', body.length, target.substring(0, 70));
        await this.respond(client, 200, 'application/vnd.apple.mpegurl', body);
      } else {
        // 分片/媒体:流式透传(边收边转发,不受单次超时限制,内存零累积)
        await this.streamPass(client, target, headers);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'upstream fail %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      try { await this.respond(client, 502, 'text/plain', 'upstream error'); } catch (_e2) { /* 已发送则忽略 */ }
    }
  }

  // m3u8 内部地址改写:非注释行(分片/子列表)→ 绝对化后包成同 headers 代理地址
  private rewriteM3u8(text: string, base: string, headers: Record<string, string>): string {
    const hj: string = b64urlEncode(JSON.stringify(headers));
    const out: string[] = [];
    for (const line of text.split(/\r?\n/)) {
      const t: string = line.trim();
      if (t === '') { out.push(''); continue; }
      if (t.startsWith('#')) { out.push(t); continue; }
      const abs: string = resolveUrl(base, t);
      out.push(this.baseUrl() + '/h/' + hj + '/' + b64urlEncode(abs));
    }
    return out.join('\n');
  }

  // 分片流式透传:上游 requestInStream 边收边转发给播放器(分段回源也不受 15s 超时限制)
  private async streamPass(client: socket.TCPSocketConnection, target: string, headers: Record<string, string>): Promise<void> {
    const req = http.createHttp();
    let headSent = false;
    const sendHead = (code: number, ctype: string): void => {
      const enc: util.TextEncoder = new util.TextEncoder();
      const head: string = 'HTTP/1.1 ' + code + ' ' + (code === 200 ? 'OK' : 'Err')
        + '\r\nContent-Type: ' + ctype
        + '\r\nConnection: close\r\n\r\n';
      try { client.send({ data: enc.encodeInto(head).buffer }); } catch (e) { /* 对端已断开 */ }
      headSent = true;
    };
    req.on('headersReceive', (h: Object): void => {
      const ch = (h as Record<string, string>)['content-type'] ?? 'video/mp2t';
      sendHead(200, ch as string);
    });
    req.on('dataReceive', (data: ArrayBuffer): void => {
      if (!headSent) { sendHead(200, 'video/mp2t'); }
      try { client.send({ data: data }); } catch (e) { /* 对端已断开 */ }
    });
    const done = new Promise<void>((resolve: (v: void | PromiseLike<void>) => void): void => {
      req.on('dataEnd', (): void => { resolve(); });
    });
    try {
      const code: number = await req.requestInStream(target, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 20000,
        readTimeout: 120000   // 大分片慢 CDN:读超时 120s(流式有数据即不触发)
      });
      if (code !== 200 && !headSent) { sendHead(200, 'video/mp2t'); }
    } catch (e) {
      if (!headSent) { sendHead(200, 'video/mp2t'); }
    }
    await done;
    try { await client.close(); } catch (e) { /* 关闭失败忽略 */ }
  }

  private async respondBytes(client: socket.TCPSocketConnection, code: number, ctype: string, body: Uint8Array): Promise<void> {
    const enc: util.TextEncoder = new util.TextEncoder();
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

export const SniffProxy: SniffProxyServer = new SniffProxyServer();
