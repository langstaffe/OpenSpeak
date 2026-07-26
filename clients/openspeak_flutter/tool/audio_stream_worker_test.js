const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const listeners = {};
const cachedResponses = new Map();
let staticFetchCount = 0;
const staticCache = {
  async match(request) {
    return cachedResponses.get(request.url)?.clone();
  },
  async put(request, response) {
    cachedResponses.set(request.url, response.clone());
  },
  async keys() {
    return [...cachedResponses.keys()].map((url) => new Request(url));
  },
  async delete(request) {
    return cachedResponses.delete(request.url);
  },
};
const context = vm.createContext({
  self: {
    registration: {scope: 'https://example.test/chat/'},
    addEventListener(type, listener) { listeners[type] = listener; },
    skipWaiting: async () => {},
    clients: {claim: async () => {}, get: async () => null},
  },
  caches: {open: async () => staticCache},
  fetch: async () => {
    staticFetchCount += 1;
    return new Response('versioned asset');
  },
  console,
  URL, Response, ReadableStream, Uint8Array, Map, Number, Date, Math,
  Promise, Error, setTimeout, clearTimeout,
});
vm.runInContext(
  fs.readFileSync(
    new URL('../web/audio_stream_worker.js', `file://${__filename}`),
    'utf8',
  ),
  context,
);

assert.deepEqual({...context.parseRange(null, 100)}, {
  start: 0, end: 99, partial: false,
});
assert.deepEqual({...context.parseRange('bytes=10-24', 100)}, {
  start: 10, end: 24, partial: true,
});
assert.deepEqual({...context.parseRange('bytes=-7', 100)}, {
  start: 93, end: 99, partial: true,
});
assert.equal(context.parseRange('bytes=100-', 100), null);

let intercepted = false;
listeners.fetch({
  request: new Request(
    'https://example.test/__openspeak_audio__/source/song.mp3?size=100',
  ),
  respondWith() { intercepted = true; },
});
assert.equal(intercepted, false);

listeners.fetch({
  request: new Request(
    'https://example.test/chat/assets-v-build-1/canvaskit/canvaskit.wasm',
    {headers: {Range: 'bytes=0-1'}},
  ),
  respondWith() { intercepted = true; },
});
assert.equal(intercepted, false);

async function testHeadWithoutClient() {
  const url = new URL(
    'https://example.test/chat/__openspeak_audio__/source/song.mp3?size=100&type=audio%2Fmpeg',
  );
  const response = await context.streamAudio({
    request: new Request(url, {
      method: 'HEAD',
      headers: {Range: 'bytes=10-24'},
    }),
    clientId: '',
  }, url, '/chat/__openspeak_audio__/');
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('Content-Range'), 'bytes 10-24/100');
}

async function testVersionedStaticCache() {
  const request = new Request(
    'https://example.test/chat/assets-v-build-1/canvaskit/canvaskit.wasm',
  );
  const dispatch = () => {
    let response;
    let lifetime;
    listeners.fetch({
      request,
      respondWith(value) { response = value; },
      waitUntil(value) { lifetime = value; },
    });
    return {response, lifetime};
  };

  const first = dispatch();
  assert.equal(await (await first.response).text(), 'versioned asset');
  await first.lifetime;
  const second = dispatch();
  assert.equal(await (await second.response).text(), 'versioned asset');
  await second.lifetime;
  assert.equal(staticFetchCount, 1);

  const nextVersionRequest = new Request(
    'https://example.test/chat/assets-v-build-2/main.dart.js',
  );
  let nextVersionResponse;
  let nextVersionLifetime;
  listeners.fetch({
    request: nextVersionRequest,
    respondWith(value) { nextVersionResponse = value; },
    waitUntil(value) { nextVersionLifetime = value; },
  });
  await nextVersionResponse;
  await nextVersionLifetime;
  assert.equal(cachedResponses.has(request.url), false);
  assert.equal(cachedResponses.has(nextVersionRequest.url), true);
}

Promise.all([testHeadWithoutClient(), testVersionedStaticCache()]).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
