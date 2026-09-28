// SPDX-License-Identifier: GPL-3.0-only
import { http } from '@kit.NetworkKit';
import { ApiRequest, ApiResponse, Field, Transport } from '../core/Models';

export class NativeTransport implements Transport {
  private timeoutSeconds: number;
  constructor(timeoutSeconds: number = 10) { this.timeoutSeconds = timeoutSeconds; }
  async send(request: ApiRequest): Promise<ApiResponse> {
    const connection = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: request.method === 'GET' ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: request.headers, expectDataType: request.binary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
        connectTimeout: this.timeoutSeconds * 1000, readTimeout: Math.max(20, this.timeoutSeconds) * 1000, usingCache: false,
        maxLimit: 20 * 1024 * 1024
      };
      // A loopback server belongs to this device, never to the system proxy host.
      if (/^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?(?:\/|$)/i.test(request.url)) {
        options.usingProxy = false;
      }
      if (request.fields.length || request.upload) {
        const parts: http.MultiFormData[] = request.fields.map((f: Field): http.MultiFormData => {
          return { name: f.name, contentType: 'text/plain', data: f.value };
        });
        if (request.upload) {
          parts.push({ name: 'torrents', contentType: 'application/x-bittorrent',
            remoteFileName: request.upload.name, data: request.upload.data });
        }
        request.headers['Content-Type'] = 'multipart/form-data';
        options.multiFormDataList = parts;
      } else if (request.method === 'POST') {
        options.extraData = request.body;
      }
      const result = await connection.request(request.url, options);
      const headers = result.header as Record<string, string | string[]>;
      const setCookie = headers['set-cookie'] || headers['Set-Cookie'];
      let cookies = result.cookies || '';
      if (typeof setCookie === 'string') { cookies = setCookie; }
      else if (Array.isArray(setCookie)) { cookies = setCookie.join('; '); }
      return { status: result.responseCode, body: request.binary ? '' : result.result as string, cookies: cookies,
        data: request.binary ? result.result as ArrayBuffer : undefined };
    } catch (error) {
      throw new Error('无法连接服务器，请检查网络、地址、端口和 HTTPS 证书。');
    } finally {
      connection.destroy();
    }
  }
}
