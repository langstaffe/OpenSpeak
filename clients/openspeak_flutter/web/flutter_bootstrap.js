{{flutter_js}}
{{flutter_build_config}}

// The server-side Web switch and custom path must take effect immediately.
// Do not install Flutter's offline app-shell service worker, which could keep
// serving a disabled or moved entry point from the browser cache.
window.addEventListener('flutter-first-frame', () => document.getElementById('loading')?.remove(), {once: true});
window.openSpeakAudioStreamWorkerReady = false;

async function registerAudioStreamWorker() {
  if (!('serviceWorker' in navigator)) return;
  try {
    const workerUrl = new URL('audio_stream_worker.js', document.baseURI);
    const updateReady = () => {
      window.openSpeakAudioStreamWorkerReady =
        navigator.serviceWorker.controller?.scriptURL === workerUrl.href;
    };
    navigator.serviceWorker.addEventListener('controllerchange', updateReady);
    await navigator.serviceWorker.register(workerUrl, {
      scope: new URL('./', document.baseURI).pathname,
    });
    if (navigator.serviceWorker.controller?.scriptURL !== workerUrl.href) {
      await Promise.race([
        new Promise((resolve) => navigator.serviceWorker.addEventListener('controllerchange', resolve, {once: true})),
        new Promise((resolve) => setTimeout(resolve, 3000)),
      ]);
    }
    updateReady();
  } catch (error) {
    console.warn('OpenSpeak audio streaming worker unavailable:', error);
  }
}

registerAudioStreamWorker().finally(() => _flutter.loader.load({config: {
  canvasKitBaseUrl: 'canvaskit',
  fontFallbackBaseUrl: 'fonts/',
}}));
