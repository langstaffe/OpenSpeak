{{flutter_js}}
{{flutter_build_config}}

// The server-side Web switch and custom path must take effect immediately.
// Do not install Flutter's offline app-shell service worker, which could keep
// serving a disabled or moved entry point from the browser cache.
window.addEventListener('flutter-first-frame', () => document.getElementById('loading')?.remove(), {once: true});
_flutter.loader.load({config: {canvasKitBaseUrl: 'canvaskit'}});
