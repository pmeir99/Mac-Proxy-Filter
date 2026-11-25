"""Compare fresh direct and PAC-routed loads in regular Chrome on the CI Mac."""
from io import BytesIO
from pathlib import Path
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
    assert bounds == new_bounds, "The filter changed a tile or image rectangle"
    delta = ImageChops.difference(before, after)
    assert delta.crop((45, 35, 104, 70)).getbbox(), "Selected portrait unchanged in Chrome"
    assert delta.crop((166, 0, 550, 190)).getbbox() is None, "Unselected portrait or clear product changed"
    assert delta.getpixel((17,17)) == (0,0,0), "Rounded clip changed"
    assert delta.getpixel((90,155)) == (0,0,0), "Foreground overlay changed"
    print("Chrome PAC comparison passed for selected and direct images, tile bounds, circle clip and foreground overlay")
