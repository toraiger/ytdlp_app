"""Exercise WebView media suppression with real HTML audio/video in Chromium.

Uses only generated audio and the actual Dart document-start script. No account,
YouTube network access, exported cookies or API credentials are needed.
"""
import base64
import io
from pathlib import Path
import re
import struct
import wave

from playwright.sync_api import sync_playwright

source = (Path(__file__).resolve().parents[1] / 'lib/services/youtube_media_guard.dart').read_text()
script = re.search(r"const youtubeMediaGuard = r'''(.*?)''';", source, re.S).group(1)
with io.BytesIO() as buffer:
    with wave.open(buffer, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(struct.pack('<h', 0) * 8000 * 3)
    audio_uri = 'data:audio/wav;base64,' + base64.b64encode(buffer.getvalue()).decode()

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', headless=True,
                               args=['--no-sandbox', '--autoplay-policy=no-user-gesture-required'])
    try:
        page = browser.new_page()
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.add_init_script(script)
        html = ('<html><body><button id="play">Play</button><audio id="audio" src="' + audio_uri + '"></audio>'
                '<script>document.querySelector("#play").onclick=()=>document.querySelector("audio").play();</script>'
                '</body></html>')
        page.route('https://www.youtube.com/**', lambda route: route.fulfill(body=html, content_type='text/html'))
        page.goto('https://www.youtube.com/')
        page.click('#play')
        page.wait_for_timeout(300)
        assert page.eval_on_selector('audio', '(e)=>e.paused && e.muted && e.currentTime===0')
        # YouTube SPA-style transitions replace media elements without a reload.
        page.evaluate('''src => {
          history.pushState({}, '', '/watch?v=aaaaaaaaaaa');
          document.querySelector('audio').remove();
          const video=document.createElement('video'); video.src=src; video.autoplay=true;
          document.body.appendChild(video); video.play();
        }''', audio_uri)
        page.wait_for_timeout(300)
        assert page.eval_on_selector('video', '(e)=>e.paused && e.muted && e.currentTime===0')
        page.evaluate('''() => {
          const frame=document.createElement('iframe');
          frame.src='https://www.youtube.com/frame'; document.body.appendChild(frame);
        }''')
        page.wait_for_function('document.querySelector("iframe").contentDocument?.querySelector("audio")')
        frame = page.frames[1]
        frame.click('#play')
        page.wait_for_timeout(300)
        assert frame.eval_on_selector('audio', '(e)=>e.paused && e.muted && e.currentTime===0')
        # A separate player context remains able to play the same generated data.
        control = browser.new_page()
        control.set_content('<audio id="control"></audio>')
        control.eval_on_selector('audio', '(e, src)=>{e.src=src; return e.play();}', audio_uri)
        control.wait_for_function('document.querySelector("audio").currentTime>0.1')
        assert not errors, errors
        print('PASS: real HTML audio, dynamic video, iframe and SPA navigation stay silent; independent player plays.')
    finally:
        browser.close()
