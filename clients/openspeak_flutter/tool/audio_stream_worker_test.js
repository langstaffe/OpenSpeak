const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const listeners = {};
const context = vm.createContext({
  self: {
    registration: {scope: 'https://example.test/chat/'},
    addEventListener(type, listener) { listeners[type] = listener; },
    skipWaiting: async () => {},
    clients: {claim: async () => {}, get: async () => null},
  },
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
