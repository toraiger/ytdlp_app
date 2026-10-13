import json
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

titles = ["夜の余白", "風をあつめて", "街の灯り", "Slow morning", "遠い海"]
requests = []
items = [
    {"video_id":str(i),"title":title,"channel":"Mix Player テスト音源","duration":12}
    for i,title in enumerate(titles)
]
audio = Path("/tmp/mix-smoke.m4a").read_bytes()
video = Path("/tmp/mix-smoke.mp4").read_bytes()

def api_route(route):
    request = route.request
    headers={"access-control-allow-origin":"*",
             "access-control-allow-headers":"content-type,x-api-key,accept",
             "access-control-allow-methods":"POST, OPTIONS"}
    if request.method == "OPTIONS":
        route.fulfill(status=204,headers=headers)
        return
    assert request.method == "POST"
    assert request.headers.get("x-api-key") == "browser-test-key"
    body=json.loads(request.post_data)
    requests.append(request.url.split("/")[-1])
    if request.url.endswith("/stream"):
        id=body["video_id"]
        response={"video_id":id,"title":titles[int(id)],
                  "audio":{"url":"https://media.example.test/"+id+".m4a"},
                  "video_audio":{"url":"https://media.example.test/"+id+".mp4"}}
    else:
        assert body["count"]==20
        response={"session_id":"browser-test","playlist_title":"Evening Mix · テスト",
                  "items":items}
    route.fulfill(status=200,content_type="application/json",body=json.dumps(response),headers=headers)

def media_route(route):
    assert "x-api-key" not in route.request.headers
    is_video=route.request.url.endswith(".mp4")
    route.fulfill(status=200,content_type="video/mp4" if is_video else "audio/mp4",
                  body=video if is_video else audio,
                  headers={"access-control-allow-origin":"*","accept-ranges":"bytes"})

with sync_playwright() as p:
    browser=p.chromium.launch(executable_path="/usr/bin/chromium",headless=True,
        args=["--no-sandbox","--autoplay-policy=no-user-gesture-required"])
    try:
        page=browser.new_page(viewport={"width":390,"height":844},device_scale_factor=1)
        errors=[]
        page.on("pageerror",lambda error:errors.append(str(error)))
        page.route("https://mix-api.example.test/**",api_route)
        page.route("https://media.example.test/**",media_route)
        page.goto("http://127.0.0.1:8080",wait_until="networkidle")
        page.wait_for_selector("flt-glass-pane",state="attached")
        page.locator("flt-semantics-placeholder").evaluate("(element)=>element.click()")
        page.get_by_role("button",name="API サーバー設定",exact=True).click()
        expect(page.get_by_role("textbox")).to_have_count(2)
        page.get_by_role("textbox").nth(0).fill("https://mix-api.example.test")
        page.wait_for_timeout(200)
        page.get_by_role("textbox").nth(1).fill("browser-test-key")
        page.wait_for_timeout(200)
        page.get_by_role("button",name="保存",exact=True).click()
        page.get_by_role("button",name="Mix を20曲取得",exact=True).click()
        expect(page.get_by_text("Evening Mix · テスト",exact=False)).to_be_visible()
        print("Mix fetched and settings saved.")
        print("Radios:",page.get_by_role("radio").count())
        print("Clickable labels:",page.locator("[role=radio]").evaluate_all("(els)=>els.map(e=>e.getAttribute('aria-label'))"))
        page.get_by_role("button",name="1 夜の余白 Mix Player テスト音源 00:12",exact=True).click()
        expect(page.get_by_role("button",name="一時停止",exact=True)).to_be_visible(timeout=15000)
        page.wait_for_timeout(2500)
        print("Slider state:",page.locator("[role=slider]").evaluate_all("(els)=>els.map(e=>({now:e.getAttribute('aria-valuenow'),text:e.getAttribute('aria-valuetext')}))"))
        print("Body:",page.locator("body").inner_text()[-1800:])
        page.screenshot(path="/tmp/mix-playing.png")
        expect(page.get_by_text("街の灯り",exact=False)).to_have_count(2,timeout=35000)
        print("Three tracks played automatically in order.")
        page.get_by_role("button",name="次の曲",exact=True).click()
        expect(page.get_by_text("Slow morning",exact=False)).to_have_count(2)
        page.get_by_role("button",name="停止",exact=True).click()
        expect(page.get_by_text("再生する曲を選択",exact=False)).to_be_visible()
        print("Audio transport verified.")
        page.get_by_role("radio",name="動画＋音声",exact=True).click()
        page.get_by_role("button",name="1 夜の余白 Mix Player テスト音源 00:12",exact=True).click()
        expect(page.locator("video")).to_have_count(1,timeout=15000)
        page.wait_for_timeout(2000)
        state=page.locator("video").evaluate("(v)=>({time:v.currentTime,duration:v.duration,paused:v.paused,error:v.error?.code})")
        print("Video state:",state)
        assert state["time"]>0 and state["error"] is None and not state["paused"]
        page.screenshot(path="/tmp/mix-video.png")
        expect(page.get_by_text("風をあつめて",exact=False)).to_have_count(2,timeout=20000)
        expect(page.locator("video")).to_have_count(1)
        print("Video transitioned automatically to the second track.")
        page.get_by_role("button",name="停止",exact=True).click()
        expect(page.locator("video")).to_have_count(0)
        assert errors==[],errors
        print("PASS: settings, /mix, audio decode/transport, video decode/stop; no page errors.")
    finally:
        browser.close()
