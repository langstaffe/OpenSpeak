const CHUNK_BYTES = 1024 * 1024;
const REQUEST_TIMEOUT_MS = 30000;
const pendingRanges = new Map();
let nextRequestId = 0;

self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.type !== 'openspeak-audio-range-result') return;
  const pending = pendingRanges.get(data.requestId);
  if (!pending) return;
  pendingRanges.delete(data.requestId);
  clearTimeout(pending.timeout);
  if (data.error) {
    pending.reject(new Error(data.error));
    return;
  }
  pending.resolve(new Uint8Array(data.bytes));
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  const audioPath = new URL('__openspeak_audio__/', self.registration.scope).pathname;
  if (!url.pathname.startsWith(audioPath)) return;
  event.respondWith(streamAudio(event, url, audioPath));
});

async function streamAudio(event, url, audioPath) {
  const size = Number.parseInt(url.searchParams.get('size') || '', 10);
  const contentType = url.searchParams.get('type') || 'application/octet-stream';
  const sourceId = url.pathname.slice(audioPath.length).split('/', 1)[0];
  if (!sourceId || !Number.isSafeInteger(size) || size <= 0) {
    return new Response('invalid audio stream', {status: 400});
  }

  const range = parseRange(event.request.headers.get('Range'), size);
  if (!range) {
    return new Response(null, {
      status: 416,
      headers: {'Content-Range': `bytes */${size}`},
    });
  }

  const headers = {
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
    'Content-Length': String(range.end - range.start + 1),
    'Content-Type': contentType,
  };
  if (range.partial) {
    headers['Content-Range'] = `bytes ${range.start}-${range.end}/${size}`;
  }
  if (event.request.method === 'HEAD') {
    return new Response(null, {status: range.partial ? 206 : 200, headers});
  }

  const client = await self.clients.get(event.clientId);
  if (!client) return new Response('audio client is unavailable', {status: 503});

  let offset = range.start;
  const body = new ReadableStream({
    async pull(controller) {
      if (offset > range.end) {
        controller.close();
        return;
      }
      try {
        const end = Math.min(range.end, offset + CHUNK_BYTES - 1);
        const bytes = await requestRange(client, sourceId, offset, end);
        if (bytes.byteLength === 0 || bytes.byteLength > end - offset + 1) {
          throw new Error('invalid audio range response');
        }
        offset += bytes.byteLength;
        controller.enqueue(bytes);
      } catch (error) {
        controller.error(error);
      }
    },
  });
  return new Response(body, {status: range.partial ? 206 : 200, headers});
}

function parseRange(value, size) {
  if (!value) return {start: 0, end: size - 1, partial: false};
  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim());
  if (!match || (!match[1] && !match[2])) return null;
  let start;
  let end;
  if (!match[1]) {
    const suffix = Number.parseInt(match[2], 10);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number.parseInt(match[1], 10);
    end = match[2] ? Number.parseInt(match[2], 10) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)) return null;
    if (start >= size || end < start) return null;
    end = Math.min(end, size - 1);
  }
  return {start, end, partial: true};
}

function requestRange(client, sourceId, start, endInclusive) {
  const requestId = `${Date.now()}-${nextRequestId++}`;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingRanges.delete(requestId);
      reject(new Error('audio range request timed out'));
    }, REQUEST_TIMEOUT_MS);
    pendingRanges.set(requestId, {resolve, reject, timeout});
    client.postMessage({
      type: 'openspeak-audio-range-request',
      requestId,
      sourceId,
      start,
      endInclusive,
    });
  });
}
