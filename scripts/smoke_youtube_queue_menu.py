'''Exercise the actual WebView long-press script in Chromium, without YouTube.

The bridge is a fixture: no cookies, media URLs or external API are used.
'''
from pathlib import Path
import re

from playwright.sync_api import sync_playwright


def main():
    project_root = Path(__file__).resolve().parents[1]
    source = (project_root / 'lib/services/youtube_queue_menu_script.dart').read_text()
    script = re.search(r'const source = r"""(.*?)""";', source, re.S).group(1)
    # Shorten only the test delay; production uses Flutter gesture constants.
    long_press_delay_ms = 100
    timer_margin_ms = 60
    touch_slop = 18
    script = (script.replace('__LONG_PRESS_DELAY__', str(long_press_delay_ms))
              .replace('__TOUCH_SLOP__', str(touch_slop))
              .replace('__HANDLER_NAME__', 'queueMenuTest'))
    fixture = '''<!doctype html><html><head></head><body>
      <a id="video" role="button" href="/watch?v=aaaaaaaaaaa&list=RDaaaaaaaaaaa"><img id="thumbnail"
        alt="Video thumbnail" style="width:100px;height:100px"><span id="title">Video title</span></a>
      <a id="short" href="/shorts/bbbbbbbbbbb">Short</a>
      <a id="channel" href="/@channel">Channel</a>
      <a id="external" href="https://youtube.com.evil.test/watch?v=aaaaaaaaaaa">External</a>
      <video id="player" style="width:150px;height:100px"></video>
      <input id="input" value="editable">
      <div style="height:2000px"></div>
    </body></html>'''
    bridge = '''window.queueMessages = [];
      window.flutter_inappwebview = {
        callHandler: (handler, target) => {
          window.queueMessages.push({handler, target}); return Promise.resolve();
        }
      };
      document.addEventListener("click", (event) => {
        if (event.target.closest("a")) {
          window.fixtureClicks = (window.fixtureClicks || 0) + 1;
          event.preventDefault();
        }
      });'''

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path='/usr/bin/chromium', headless=True,
            args=['--no-sandbox'],
        )
        try:
            page = browser.new_page(has_touch=True)
            errors = []
            page.on('pageerror', lambda failure: errors.append(str(failure)))
            page.add_init_script(bridge)
            page.add_init_script(script)
            page.route('https://www.youtube.com/**',
                       lambda route: route.fulfill(body=fixture, content_type='text/html'))
            page.goto('https://www.youtube.com/watch?v=ccccccccccc')

            def message_count():
                return page.evaluate('window.queueMessages.length')

            def hold(selector):
                page.locator(selector).hover()
                page.mouse.down()
                page.wait_for_timeout(long_press_delay_ms + timer_margin_ms)
                page.mouse.up()

            # Reinjecting during SPA updates must not install duplicate listeners.
            page.evaluate(script)
            hold('#thumbnail')
            assert message_count() == 1
            message = page.evaluate('window.queueMessages[0]')
            assert message['handler'] == 'queueMenuTest'
            assert message['target']['url'] == 'https://www.youtube.com/watch?v=aaaaaaaaaaa'
            assert message['target']['title'] == 'Video title'
            assert page.evaluate('window.fixtureClicks || 0') == 0
            assert page.url.endswith('watch?v=ccccccccccc')
            page.dispatch_event('#thumbnail', 'contextmenu')
            assert message_count() == 1

            # A subsequent normal tap still reaches the page once.
            page.click('#title')
            assert page.evaluate('window.fixtureClicks') == 1
            assert message_count() == 1
            hold('#title')
            hold('#short')
            hold('#player')
            assert message_count() == 4
            assert page.evaluate('window.queueMessages[3].target.url').endswith('ccccccccccc')

            # Browser touch input emits the same pointer sequence on mobile.
            thumbnail_bounds = page.locator('#thumbnail').bounding_box()
            touch_point = {
                'x': thumbnail_bounds['x'] + thumbnail_bounds['width'] / 2,
                'y': thumbnail_bounds['y'] + thumbnail_bounds['height'] / 2,
            }
            session = page.context.new_cdp_session(page)
            session.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [touch_point]})
            page.wait_for_timeout(long_press_delay_ms + timer_margin_ms)
            session.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
            assert message_count() == 5

            # Moving beyond Flutter touch slop, scrolling, or cancellation aborts a hold.
            for event_name in ['pointermove', 'scroll', 'pointercancel']:
                page.locator('#title').hover()
                page.mouse.down()
                if event_name == 'pointermove':
                    page.mouse.move(400, 300)
                elif event_name == 'scroll':
                    page.evaluate('document.dispatchEvent(new Event("scroll"))')
                else:
                    page.dispatch_event('#title', 'pointercancel')
                page.wait_for_timeout(long_press_delay_ms + timer_margin_ms)
                page.mouse.up()
                assert message_count() == 5, event_name

            for selector in ['#channel', '#external', '#input']:
                hold(selector)
                assert message_count() == 5, selector

            # The same script cannot emit selections from an iframe or non-YouTube page.
            page.evaluate('''() => {
              const frame = document.createElement("iframe");
              frame.src = "/frame"; document.body.prepend(frame);
            }''')
            page.wait_for_function('document.querySelector("iframe").contentDocument?.querySelector("#title")')
            frame = page.frames[1]
            frame.dispatch_event('#title', 'contextmenu')
            assert frame.evaluate('window.queueMessages.length') == 0
            page.route('https://www.google.com/**',
                       lambda route: route.fulfill(body=fixture, content_type='text/html'))
            page.goto('https://www.google.com/')
            hold('#thumbnail')
            assert message_count() == 0
            assert not errors, errors
            print('PASS: video targets, duplicate suppression, normal taps, scroll/cancel, SPA reinjection and frame/host isolation.')
        finally:
            browser.close()


if __name__ == '__main__':
    main()
