/// Document-local gesture state is deliberately kept in a closure. Only video
/// targets suppress native callouts; ordinary links and scrolling keep working.
String youtubeQueueMenuScript({
  required Duration longPressDelay,
  required double touchSlop,
  required String handlerName,
}) {
  const source = r"""
(() => {
  if (window !== window.top || window.__mixPlayerQueueMenu) return;
  const videoHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"];
  if (location.protocol !== "https:" || !videoHosts.includes(location.hostname)) return;
  window.__mixPlayerQueueMenu = true;
  const longPressDelay = __LONG_PRESS_DELAY__;
  const touchSlop = __TOUCH_SLOP__;
  const maximumTitleLength = 300;
  const handlerName = "__HANDLER_NAME__";
  let pending = null;
  let timer = null;
  let gestureHandled = false;
  let suppressClick = false;

  const videoUrl = (value) => {
    try {
      const url = new URL(value, location.href);
      if ((url.protocol !== "https:") || url.username || url.password ||
          (url.port && url.port !== "443")) return null;
      let videoId = null;
      if (videoHosts.includes(url.hostname)) {
        if (url.pathname === "/watch") videoId = url.searchParams.get("v");
        const pathMatch = url.pathname.match(/^\/(?:shorts|live)\/([A-Za-z0-9_-]{11})\/?$/);
        if (pathMatch) videoId = pathMatch[1];
      } else if (url.hostname === "youtu.be") {
        videoId = url.pathname.slice(1);
      }
      return (videoId && /^[A-Za-z0-9_-]{11}$/.test(videoId))
        ? "https://www.youtube.com/watch?v=" + videoId : null;
    } catch (failure) { return null; }
  };

  const targetAt = (element) => {
    if (!(element instanceof Element)) return null;
    if (element.closest("button,input,textarea,select,[contenteditable]")) return null;
    const anchor = element.closest("a[href]");
    // YouTube may mark video links themselves as buttons. Ignore playback
    // controls while still accepting those links and their thumbnail children.
    if (!anchor && element.closest("[role=button]")) return null;
    const player = element.closest("video,#movie_player,#player-container-id,h1");
    const url = anchor ? videoUrl(anchor.href) : (player ? videoUrl(location.href) : null);
    if (!url) return null;
    const card = element.closest("ytd-rich-item-renderer,ytd-video-renderer,ytm-rich-item-renderer,ytm-video-with-context-renderer");
    const titleElement = card?.querySelector("#video-title,h3,h4") || anchor || player;
    const title = (titleElement?.getAttribute("title") ||
      titleElement?.getAttribute("aria-label") || titleElement?.textContent || "").trim();
    return {url, title: title.slice(0, maximumTitleLength), pageUrl: location.href};
  };

  const cancel = () => {
    clearTimeout(timer);
    timer = null;
    pending = null;
  };

  const showMenu = (target) => {
    if (gestureHandled || target.pageUrl !== location.href) return;
    const bridge = window.flutter_inappwebview;
    if (!bridge?.callHandler) return;
    gestureHandled = true;
    suppressClick = true;
    clearTimeout(timer);
    timer = null;
    Promise.resolve(bridge.callHandler(handlerName, target)).catch(() => {});
  };

  document.addEventListener("pointerdown", (event) => {
    cancel();
    gestureHandled = false;
    suppressClick = false;
    if (!event.isPrimary || event.button !== 0) return;
    const target = targetAt(event.target);
    if (!target) return;
    pending = {target, pointerId: event.pointerId, startX: event.clientX, startY: event.clientY};
    timer = setTimeout(() => {
      if (pending) showMenu(pending.target);
    }, longPressDelay);
  }, true);

  document.addEventListener("pointermove", (event) => {
    if (!pending || pending.pointerId !== event.pointerId) return;
    const distance = Math.hypot(event.clientX - pending.startX, event.clientY - pending.startY);
    if (distance > touchSlop) cancel();
  }, true);
  for (const eventName of ["pointerup", "pointercancel", "scroll"]) {
    document.addEventListener(eventName, cancel, true);
  }
  // Some WebViews emit contextmenu before the timer or after pointerup.
  // Handling both paths once prevents two sheets for the same gesture.
  document.addEventListener("contextmenu", (event) => {
    const target = targetAt(event.target);
    if (!target) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    showMenu(target);
  }, true);
  document.addEventListener("click", (event) => {
    if (!suppressClick) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    suppressClick = false;
  }, true);
  const installStyle = () => {
    const style = document.createElement("style");
    style.textContent = `a[href*="/watch?"],a[href*="/shorts/"],a[href*="/live/"],
      a[href*="youtu.be/"],video,#movie_player,#player-container-id {
      -webkit-touch-callout: none;
    }`;
    document.documentElement.appendChild(style);
  };
  if (document.documentElement) installStyle();
  else document.addEventListener("DOMContentLoaded", installStyle, {once: true});
})();
""";
  return source
      .replaceAll(
        "__LONG_PRESS_DELAY__",
        longPressDelay.inMilliseconds.toString(),
      )
      .replaceAll("__TOUCH_SLOP__", touchSlop.toString())
      .replaceAll("__HANDLER_NAME__", handlerName);
}
