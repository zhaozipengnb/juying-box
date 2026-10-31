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
    try {
      const r = await httpFetch(target, { headers: headers });
      let ctype: string = r.headers['content-type'] ?? 'application/octet-stream';
      hilog.info(0x0000, TAG, 'serve %{public}d %{public}s', r.status, target.substring(0, 80));
      let body: string = '';
      const isM3u8: boolean = ctype.indexOf('mpegurl') >= 0 || /\.m3u8($|\?)/i.test(target);
      if (isM3u8) {
        // m3u8:分片/密钥地址改写为同 headers 的代理地址(嵌套)
        body = this.rewriteM3u8(r.text(), target, headers);
        ctype = 'application/vnd.apple.mpegurl';
      } else {
        body = r.text();
      }
      await this.respond(client, r.status, ctype, body);
    } catch (e) {
      hilog.error(0x0000, TAG, 'upstream fail %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      await this.respond(client, 502, 'text/plain', 'upstream error');
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
