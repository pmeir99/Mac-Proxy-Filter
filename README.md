# Mac Proxy Filter

Mac Proxy Filter is a local macOS proxy that masks people in website images. Use ordinary Chrome, choose which image hosts to filter, and set how much of each person to cover. The app inspects eligible images before it sends them to the browser. When it detects no person, it returns the original image. Recognition and masking run on your Mac.

**Current status:** Development preview for Apple silicon, with a macOS 14 minimum deployment target. The ZIP includes the proxy engine, its Python runtime, and the thumbnail model. Setup requires macOS approval for HTTPS trust and network routing. No extension, account, Terminal installation, or model download is required. [Download a Mac Proxy Filter preview](https://github.com/pmeir99/Mac-Proxy-Filter/releases)

## Set up and verify filtering

1. Download **Mac-Proxy-Filter.zip**, unzip it in Finder, move **Mac Proxy Filter** to Applications, and open it.
2. In **Overview → Websites**, select **Filter all public websites**, or enter one exact destination hostname per line under **Included hosts**. Use hostnames without a scheme, path, or wildcard. If an Amazon image URL begins with `https://m.media-amazon.com/`, enter `m.media-amazon.com`. Adding `amazon.com` alone will miss that request. A shared image host is filtered on every page that uses it. **Connect directly to these hosts** gives exact hosts an exception.
3. Click **Enable filtering…** and approve the setup dialogs. The app creates a local certificate authority, verifies HTTPS trust, and configures the system proxy on eligible network services. Wi-Fi networks using the same service share its settings. Setup reports services it skips because another proxy is active. Run **Check or repair setup…** after adding a network service or if routing or trust fails.
4. Look for **Enabled on current network**. Reload an in-scope page in Chrome and check the request and image counters. To test a fresh transfer, open DevTools → Network, select **Disable cache**, keep DevTools open, and reload. Compare a portrait and a product-only image from the same image host. A setup check can increment the request count on its own.

## What happens to an image

| Stage | Current behavior |
| --- | --- |
| Route | A proxy auto-configuration (PAC) file sends selected destinations to the local proxy in browsers that honor macOS proxy settings. In all-sites mode, local names and literal IP addresses go direct. |
| Inspect | The proxy verifies the upstream HTTPS certificate and holds eligible still-image responses for scanning. The current limits are 8 MiB for the image body and 12 megapixels for decoding. |
| Detect | A resident Swift worker uses Apple Vision person segmentation for larger images. At 256 pixels or less on the longest side it uses the bundled DeepLabV3 FP16 Core ML model, and runs localized person or face detection when either model returns an empty mask. Repeated image content can reuse a cached result. |
| Render | A clear result preserves the image bytes. A positive result normally returns a full-size PNG with a Core Image blur or solid cover. Chrome still owns the element, crop, border radius and overlays. For an image marked `no-transform`, a clear result passes through and an image requiring a mask is withheld. |
| Handle failures | Recognized image requests with an unreadable or unsupported body, missing length, partial content, or a scan failure can be withheld. A missing thumbnail can therefore be a filtering decision even when the page loads. |

## App controls

- **Overview** controls website scope, HTTPS setup, login startup, and menu-bar behavior. Closing the window keeps the worker running. Enable **Keep filtering in the menu bar when I press ⌘Q** if you want the Quit shortcut to do the same. Stop filtering before editing the host lists.
- **Mask** offers Gaussian blur with adjustable strength or a solid cover with a chosen color. **Follow people** uses the detected shape. **Enclosing rectangle** covers the region containing all detections. Add up to 20% of the shorter image dimension as extra margin. Changes apply to new image requests while filtering runs.
- **Activity** captures routed request outcomes for five minutes. Turn capture on before starting. Filter by exact referring or image hostname and decision, then select a row for origin and response status, failure details, and stage timings. **Export filtered activity…** uses both filters. Capture and export default to metadata only. To share pixels, enable **Retain before and after images** before starting and **Include retained images in ZIP** before exporting. Retention is limited to 1,500 entries and 64 MiB of image payloads.
- **Updates** checks this repository on demand and offers **Download and install** when a newer proxy build is available.

To uninstall, use **Overview → Network setup → Restore previous routing…** before quitting. Remove the installation’s certificate from Keychain Access and delete the app. **Show public certificate** helps identify the certificate created by this installation.

## Coverage and troubleshooting

| Symptom | What to check |
| --- | --- |
| An image appears unchanged | Find its actual **Request URL** in Chrome DevTools. Check scope, direct exceptions, and whether Activity recorded a scan. A recorded clear decision on a visible person indicates a detection miss. Browser cache, offline service workers, inline data, blobs assembled locally, canvas and video frames can display pixels without an eligible new image transfer. |
| A page fails or shows a certificate warning | Record the exact hostname and browser error, then use **Check or repair setup…**. Clients that pin certificates can reject a locally trusted proxy. Record whether the same page loads after restoring previous routing. |
| A thumbnail is missing | With capture enabled, check the image decision and upstream HTTP status. A retailer error, a partial response, an unsupported image, and a person in a `no-transform` image call for different fixes. A referring hostname is available only when supplied by the client. |

Coverage depends on the client following system routing. Once loaded, the PAC offers only the local proxy for included destinations. A stopped listener can therefore interrupt those sites until routing is restored. Chrome can still use a direct connection if it cannot load the system PAC itself. A thumbnail, a low-resolution placeholder and the full image can have different sources and detection results. Inline HTML/CSS/SVG, script-generated pixels, embedded document content, service-worker stores and previously decoded images can reach the screen without a fresh image transfer. Starting filtering cannot recall pixels already displayed or transfers already underway. Small or crowded subjects can be missed, and objects can be misidentified.

## Verification and goals

The macOS workflow tests the extracted app against a local HTTPS origin, compares portrait and object-only fixtures, and checks direct versus filtered Chrome rendering, including a circular crop and an overlay. Retail probes exercise individual Best Buy and Home Depot image responses. Those checks cover specific fixtures and URLs. Full storefront navigation and detection accuracy across a retailer’s catalog remain open. [Passing verification run](https://github.com/pmeir99/Mac-Proxy-Filter/actions/runs/45915209038) · [Test suite](tests)

The immediate goal is reliable people-only masking on an M4 Mac with 16 GB of memory. Priorities are fewer missed thumbnails and false positives, fewer unnecessarily withheld images, and measured latency on image-heavy pages. Clothing or modesty levels, skin-only masks, selective masking by sex, and product-category detection are outside the current preview.

## Build from source

On an Apple silicon Mac with the Xcode tools, run `bash build.sh`. The build downloads and verifies the pinned proxy bundle and Core ML model, then produces an ad-hoc-signed app in `dist/`. To run the routing and policy tests separately, use `python3 tests/policy_test.py` with Node.js installed. [Build script](build.sh) · [Verification workflow](.github/workflows/verify.yml)

For editing a photo you open yourself, see the [standalone image editor](https://github.com/pmeir99/Image-Filtration-V1).

[Current architecture and diagnostic fields](docs/architecture.md) · [Engineering decisions and remaining validation](docs/engineering-review.md)

The proxy buffers recognized image responses before deciding what to deliver. Unrecognized generic binary data, oversized or lengthless candidate bodies, and non-success image bodies can be withheld. Gaussian blur uses a binary coverage mask and one radius within a given image. The blurred colors still follow the source lighting. Solid cover provides a single color.

Fresh routed HTML documents receive an additional Content Security Policy allowing HTTP(S) image sources only. Data and blob previews, including legitimate icons, may appear blank. Route the document host as well as its image hosts. Embedded bytes may still be present in the document. Canvas, inline SVG geometry, video, previously cached documents and unfiltered frames are outside this image-source rule.
