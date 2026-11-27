"""Compare fresh direct and PAC-routed loads in regular Chrome on the CI Mac."""
from io import BytesIO
from pathlib import Path
import os
from PIL import Image, ImageChops
from playwright.sync_api import sync_playwright

PAGE = """<!doctype html><meta charset="utf-8">
<style>
body {margin: 16px; background: #eee}
main {display:flex; gap:12px}
.tile {width:150px;height:150px;position:relative;overflow:hidden;border-radius:50%}
img {width:100%;height:100%;object-fit:cover;display:block}
.tile::after {content:"";position:absolute;bottom:0;left:0;width:100%;height:20px;background:green}
</style><main>
<div class="tile"><img src="http://origin.test:18280/portrait.png"></div>
<div class="tile"><img src="http://outside.test:18280/portrait.png"></div>
<div class="tile"><img src="http://origin.test:18280/coffee.png"></div></main>"""

def compare(directory):
    (directory / "page.html").write_text(PAGE)
    with sync_playwright() as drivers:
        def capture(args):
            browser = drivers.chromium.launch(channel="chrome", args=args)
            try:
                tab = browser.new_page(viewport={"width": 550, "height": 190}, device_scale_factor=1)
                tab.goto("http://outside.test:18280/page.html")
                tab.locator("img").evaluate_all("(items) => Promise.all(items.map(img => img.decode()))")
                bounds = tab.locator(".tile, img").evaluate_all(
                    "(items) => items.map(el => el.getBoundingClientRect().toJSON())")
                pixels = Image.open(BytesIO(tab.screenshot())).convert("RGB")
                return bounds, pixels
            finally:
                browser.close()

        bounds, before = capture(["--no-proxy-server"])
        new_bounds, after = capture(["--proxy-pac-url=http://127.0.0.1:17861/proxy.pac"])
    if "FILTER_TEST_EVIDENCE" in os.environ:
        evidence = Path(os.environ["FILTER_TEST_EVIDENCE"])
        evidence.mkdir(parents=True, exist_ok=True)
        before.save(evidence / "chrome-direct.png")
        after.save(evidence / "chrome-filtered.png")
    assert bounds == new_bounds, "The filter changed a tile or image rectangle"
    delta = ImageChops.difference(before, after)
    assert delta.crop((45, 35, 104, 70)).getbbox(), "Selected portrait unchanged in Chrome"
    assert delta.crop((166, 0, 550, 190)).getbbox() is None, "Unselected portrait or clear product changed"
    assert delta.getpixel((17,17)) == (0,0,0), "Rounded clip changed"
    assert delta.getpixel((90,155)) == (0,0,0), "Foreground overlay changed"
    print("Chrome PAC comparison passed for selected and direct images, tile bounds, circle clip and foreground overlay")

def verify_running_chrome(directory):
    """Exercise the existing Chrome process with normal macOS proxy discovery on a disposable runner."""
    import re
    import subprocess
    import time
    def output(*cmd):
        return subprocess.check_output(cmd,text=True)
    interface=re.search(r"interface:\s*(\S+)",output("route","-n","get","default")).group(1)
    order=output("networksetup","-listnetworkserviceorder")
    service=next(name for name,device in re.findall(r"\(\d+\) ([^\n]+)\n\(Hardware Port: [^\n]*?, Device: ([^)]+)\)",order) if device==interface)
    if "Enabled: No" not in output("networksetup","-getautoproxyurl",service):
        raise RuntimeError("Expected a clean runner without an existing PAC")
    with sync_playwright() as drivers:
        log=directory.parent/"network-log.json"
        browser=drivers.chromium.launch_persistent_context(str(directory.parent/"chrome-profile"),channel="chrome", headless=False,args=["--log-net-log="+str(log)])
        try:
            tab=browser.new_page()
            url="http://origin.test:18280/portrait.png"
            raw=(directory/"portrait.png").read_bytes()
            assert tab.goto(url+"?direct").body()==raw
            output("sudo","networksetup","-setautoproxyurl",service,"http://127.0.0.1:17861/proxy.pac?revision=live")
            output("sudo","networksetup","-setautoproxystate",service,"on")
            print("System proxy after activation:",output("scutil","--proxy"),flush=True)
            start=time.monotonic()
            while time.monotonic()-start<20:
                response=tab.goto(url+"?live="+str(time.monotonic_ns()))
                if response.ok and response.body().startswith(b"\x89PNG") and response.body()!=raw:
                    print(f"Already-running Chrome received masked image after {time.monotonic()-start:.2f}s",flush=True)
                    break
                time.sleep(.2)
            else:
                browser.close()
                import json
                net=json.loads(log.read_text())
                names={v:k for k,v in net["constants"]["logEventTypes"].items()}
                seen=set()
                for event in net["events"]:
                    name=names.get(event["type"],"")
                    if ("PROXY" in name or "PAC_" in name) and event.get("params"):
                        seen.add(name+" "+str(event["params"])[:350])
                print("Proxy diagnostics:",sorted(seen)[:70],flush=True)
                raise AssertionError("Running Chrome did not adopt the system PAC")
        finally:
            output("sudo","networksetup","-setautoproxystate",service,"off")
            browser.close()
