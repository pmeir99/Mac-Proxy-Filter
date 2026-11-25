# Mac Proxy Filter

Mac Proxy Filter is a development build for people-only blurring on a configurable set of image hosts. The SwiftUI app saves the domain list on your Mac. Ordinary Chrome can use it through the macOS automatic proxy configuration setting. Apple Vision performs segmentation locally. Core Image applies Gaussian blur through the resulting mask. There is no account, analytics service, remote model, or extension.

## Choose the scope

Start with an empty list. Enter one exact destination hostname per line. To change the list, press Stop, edit, then Start. The list persists across launches. Chrome may cache a PAC file. After changing the list, reapply the proxy setting and fully quit and reopen Chrome for your test.

For example, if a product page at `shop.example` loads a thumbnail from `images.example`, add `images.example` to cover that thumbnail. Adding only `shop.example` covers images served by the shop host itself. A selected shared CDN is filtered everywhere it is used. Subdomains require their own entries. Chrome DevTools → Network → Img → Request URL shows the actual destination. An embedded data URL has no separate network request.

## Run on your Mac

1. Download **Mac-Proxy-Filter.zip** from the latest Mac Proxy Filter preview, double-click the ZIP in Finder, drag **Mac Proxy Filter** to Applications, and open it. This Apple silicon app includes its proxy engine and Python runtime and uses the Vision framework supplied by macOS. All user setup is graphical. [Releases](https://github.com/pmeir99/Mac-Proxy-Filter/releases)
2. Enter your test image hosts and press **Start**. Wait for **Listening on this Mac**. Both listeners bind to the loopback interface.
3. For HTTPS, click **Show public certificate in Finder**. Import that specific `mitmproxy-ca-cert.pem` into your login keychain using Keychain Access, open its Trust section and enable SSL trust. The certificate is unique to this installation. Trust applies beyond the app's domain list. Keep the private key in the app's private Application Support directory. Leave normal website certificate verification enabled.
4. Record your current network proxy settings. In System Settings → Network → active service → Details → Proxies, enable **Automatic proxy configuration**, enter `http://127.0.0.1:17861/proxy.pac` and apply. A managed network may already require its own PAC. Keep the app running while using this configuration.
5. For a clean test, disable the old image-filter extension, open DevTools with **Disable cache** enabled, and reload the page. Compare a person and a product-only image on the selected host, then load an image on an unrelated host. Check the element dimensions and any CSS crop or border radius in both views. A fresh browser profile helps distinguish service-worker responses from new network transfers.

To switch back, restore the previous network proxy settings first, then stop the app. To uninstall, also remove this installation's certificate from Keychain Access and delete the app. Its locally generated key material is under `~/Library/Application Support/Mac Proxy Filter/`.

## How a request travels

| Stage | Behavior |
| --- | --- |
| Destination selection | The app serves a PAC on loopback. Supported destinations use the local proxy. Other hosts go directly to the network in PAC-aware clients. The explicit proxy also checks the destination itself. |
| HTTPS | mitmproxy terminates the selected connection locally and verifies the origin's certificate. A client that pins certificates or ignores system proxy settings may fail or bypass this route. |
| Image selection | Full 200 GET responses with a supported image MIME type, identity encoding and a declared body length of up to 8 MiB are eligible. The filter respects no-transform. Other responses stream through. |
| Recognition | A resident Swift process decodes a still image up to 12 megapixels and runs Vision on an orientation-corrected thumbnail of up to 1024 pixels on its longest side. Repeated bytes reuse an in-memory decision. No standalone model download is required. |
| Rendering | An empty detection returns the original response bytes. A positive result returns a full-resolution PNG with the detected people blurred. The page keeps its own element, positioning and CSS clipping. A scan failure on an eligible image returns HTTP 502. |

## Coverage and verification

This first build covers fresh, eligible network transfers. Existing caches, inline images, canvas drawing, offline service workers, video frames, unsupported formats, partial responses and responses without a declared size can display unmodified content. Eligible multi-frame files currently fail the still-image scan. Recognition can miss people or blur a false positive. Device throughput, tiny thumbnails, crowd scenes, and live retailer coverage require separate measurements. The worker serializes inference and retains up to 256 cached results with a 32 MiB output budget.

Run `python3 tests/policy_test.py` with Node installed to test PAC routing and TLS scope. The macOS workflow compiles and signature-checks the app. Its integration test runs the real engine against a local TLS origin, sends portrait and object-only fixtures through the Vision worker, compares bytes and output pixels, and checks refusal of an unlisted CONNECT. A second, HTTP browser fixture compares screenshots from direct and PAC-routed Chrome loads. It checks image bounds, a circular clip, an overlaid shape, and an identical portrait on an unlisted host. Test-only certificate trust is confined to the test processes. The workflow downloads the public scikit-image astronaut and coffee fixtures during CI. Runtime inference is local.

## Building from source

On an Apple silicon Mac with Xcode Command Line Tools, run `bash build.sh`. During packaging the script downloads the official arm64 mitmproxy bundle, checks its pinned SHA-256 digest, verifies its signature, and embeds it inside the app. The release workflow extracts the finished ZIP into a separate folder, checks its signature, and tests the included engine with only system directories on its executable search path. The outer app is ad-hoc signed for development.

## Design references

- Chromium documents which URL and host information is available to a PAC script. This is why the control uses destination hostnames. [Chromium proxy design](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)
- Apple provides an automatic proxy URL for each network service. DNS alone cannot supply the decoded pixels required for masking. [macOS proxy settings](https://support.apple.com/guide/mac-help/mchlp2591/mac)
- The proxy engine documents certificate generation, client trust, upstream verification and host selection. [Certificates](https://docs.mitmproxy.org/stable/concepts/certificates/) · [Options](https://docs.mitmproxy.org/stable/concepts/options/) · [Installation](https://docs.mitmproxy.org/stable/overview/installation/)
- Apple's person-segmentation request produces a foreground mask suited to compositing. [Vision segmentation](https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest)
- HTTP defines no-transform for intermediaries and separate semantics for range responses. [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) · [RFC 9111](https://www.rfc-editor.org/rfc/rfc9111.html)

### Interception options considered

| Method | Fit for this project |
| --- | --- |
| DNS proxy | DNS sees hostname lookups. It can support blocking an entire destination. Pixel masking needs access to each image response. [Apple DNS proxy](https://developer.apple.com/documentation/networkextension/nednsproxyprovider) |
| macOS content-filter extension | Apple's data provider has read-only access to flows and issues filtering verdicts. Replacing a JPEG with a composited image requires another mechanism. [Apple Network Extensions session](https://developer.apple.com/videos/play/wwdc2019/714/) |
| Chrome page extension | A page script has the embedding context and can cover inline or generated media, but has to track DOM changes and clipping. Chrome's declarative request rules also have documented limits for service-worker-generated responses. [Chrome request rules](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest/) |
| Local HTTP proxy with a PAC | Used in this build. A fresh image response can be replaced once before Chrome decodes it, regardless of whether the website used an img element or a CSS background. The browser owns the final geometry. The PAC sees the resource destination. Browser-local media and an embedding-page-only scope on a shared CDN would require browser cooperation. [Chromium PAC behavior](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md) |
