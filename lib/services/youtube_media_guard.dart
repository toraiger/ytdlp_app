// Runs at document start in every frame. Native WKWebView suspension provides
// an additional guard on iOS 15+. No page contents or cookies cross this script.
const youtubeMediaGuard = r'''
(() => {
  if (window.__mixPlayerMediaGuard || !window.HTMLMediaElement) return;
  window.__mixPlayerMediaGuard = true;
  const pause = HTMLMediaElement.prototype.pause;
  const stop = (element) => {
    element.muted = true;
    element.autoplay = false;
    pause.call(element);
  };
  try {
    Object.defineProperty(HTMLMediaElement.prototype, 'play', {
      configurable: true,
      writable: true,
      value: function() { stop(this); return Promise.resolve(); }
    });
  } catch (_) {}
  document.addEventListener('play', (event) => {
    if (event.target instanceof HTMLMediaElement) stop(event.target);
  }, true);
  const scan = (node) => {
    if (node instanceof HTMLMediaElement) stop(node);
    if (node.querySelectorAll) node.querySelectorAll('video,audio').forEach(stop);
  };
  new MutationObserver((records) => {
    for (const record of records) record.addedNodes.forEach(scan);
  }).observe(document, {childList: true, subtree: true});
  scan(document);
})();
''';
