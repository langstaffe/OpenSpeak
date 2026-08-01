{{flutter_js}}
{{flutter_build_config}}

// The server-side Web switch and custom path must take effect immediately.
// Do not install Flutter's offline app-shell service worker, which could keep
// serving a disabled or moved entry point from the browser cache.
const setLoadingProgress = (value, stage) => {
  const progress = document.getElementById('loading-progress');
  if (progress) progress.value = value;
  const loadingStage = document.getElementById('loading-stage');
  if (loadingStage) loadingStage.textContent = stage;
};
const removeLoading = () => document.getElementById('loading')?.remove();
const showLoadingError = (error) => {
  console.error('OpenSpeak failed to load:', error);
  const loadingStage = document.getElementById('loading-stage');
  if (loadingStage) loadingStage.textContent = '加载失败，请刷新页面重试';
};
const handleResourceError = (event) => {
  const source = event.target;
  if (source?.tagName === 'SCRIPT' && source.src.endsWith('/main.dart.js')) {
    showLoadingError(new Error(`Failed to load ${source.src}`));
  }
};
window.addEventListener('error', handleResourceError, true);
window.addEventListener('flutter-first-frame', () => {
  window.removeEventListener('error', handleResourceError, true);
  removeLoading();
}, {once: true});
window.openSpeakAudioStreamWorkerReady = false;
setLoadingProgress(1, '正在准备音频播放…');

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

const assetBase = __OPENSPEAK_WEB_ASSET_BASE__;
const flutterConfig = {
  assetBase,
  entrypointBaseUrl: assetBase,
  canvasKitBaseUrl: `${assetBase}canvaskit`,
  fontFallbackBaseUrl: `${assetBase}fonts/`,
};

registerAudioStreamWorker().finally(() => {
  setLoadingProgress(2, '正在加载程序…');
  _flutter.loader.load({
    config: flutterConfig,
    onEntrypointLoaded: async (engineInitializer) => {
      try {
        setLoadingProgress(3, '正在初始化渲染引擎…');
        const appRunner = await engineInitializer.initializeEngine(flutterConfig);
        setLoadingProgress(4, '正在启动 OpenSpeak…');
        await appRunner.runApp();
      } catch (error) {
        showLoadingError(error);
      }
    },
  }).catch(showLoadingError);
});
