# Current architecture

Audit a release by recording its Git tag and downloading the matching source. The proxy app and the imported-photo editor are separate projects. This repository builds the proxy.

| Component | Responsibility |
| --- | --- |
| Sources/App.swift and Interface.swift | App lifecycle, preferences, worker supervision, Activity table and user-initiated exports |
| Sources/NetworkSetup.swift | HTTPS probe, local certificate trust, system proxy setup and restoration |
| proxy/policy.py and admission.py | Destination selection for PAC, TLS and HTTP, plus reservations for concurrent image bodies |
| proxy/filter.py | Image eligibility, HTTP content decoding, result cache, request-scoped settings, worker IPC and response selection |
| Sources/Mask.swift, PersonMask.swift and FaceBoxes.swift | ImageIO decode, local face and body detection, spatial confirmation of person mattes, crop retries, Core Image composition and PNG output |
| proxy/journal.py | Bounded in-memory event retention and filtered JSON or ZIP responses through the authenticated loopback endpoint |
| Sources/Updates.swift and install-update.sh | Check GitHub, verify asset, stage the replacement and relaunch |
| build.sh, tests/ and .github/workflows/verify.yml | Package the runtime and model, test HTTPS and Chrome rendering on macOS, and publish the winning runner’s ZIP |

## Interpreting Activity

Total milliseconds run from proxy request headers to the recorded decision or transport error. A block at response headers ends there. Browser decoding, display, and client delivery after the decision are outside this interval. Completed pass-through requests are recorded while capture is enabled. Their total ends at the proxy response hook. Traffic sent directly by the PAC never reaches this logger. Byte counts refer to inspected image data; streamed pass-through bodies are not counted.

Stages are elapsed wall time rounded to milliseconds. Absent fields mean the stage was skipped or did not finish. A cache hit can therefore have no worker time.

| Field | Interval |
| --- | --- |
| waitHeadersMS, receiveBodyMS | Request start to origin response headers, then headers to the complete buffered image |
| receiveRequestMS, afterRequestToHeadersMS | First request byte to completed request, then to first response header (when ordered timestamps exist). This includes uploads, network latency and origin work. |
| connectMS, upstreamTLSMS | Upstream socket setup and TLS when newly established within this request. These intervals can overlap the intervals above. |
| prepareMS, hashMS, queueMS | Decode HTTP content encoding, validate and snapshot settings, then hash input and wait for the serialized worker |
| workerMS | Worker startup if needed, IPC, native processing and result transfer combined |
| decodeMS, localizationMS, faceLandmarksMS, objectDetectionMS, segmentationMS, confirmationMS, handPoseMS, fallbackMS, faceConfirmationMS | Within worker time, prepare the oriented thumbnail, locate people, propose and confirm person pixels, and retry unresolved locations |
| composeGraphMS, renderEncodeMS | Within worker time, construct the Core Image graph, then execute it and encode the output |

Worker stages are nested within workerMS. Adding every number double-counts that interval. For a transport error before an HTTP response, status 0 means no downstream HTTP status was available. Origin metadata is recorded only if response headers reached image classification. Error text can contain host or system details. Review exported metadata before sharing.

The ZIP contains manifest.json with one entry per matching event and mask-settings.json with settings keyed by event ID when available. Metadata-only capture does not retain image payloads in the journal. Processing and the in-memory result cache still require image bytes. Exporting metadata alone also omits image files from sessions that retained them.

The pinned mitmproxy 12.3.1 buffered-body hook in proxy/body_limit.py enforces each reservation as data arrives. Revalidate that internal API on engine upgrades. The Chrome fixture covers a locally scanned inline icon; the HTTPS suite checks unknown-length and oversized bodies. proxy/icons.py separates ICO representations, and proxy/inline_icons.py stores at most 512 origin-bound icon inputs accessible for five minutes.

## Recognition regressions

The product test fetches content-address-checked public photos listed in `tests/person-fixtures.json` on the build Mac. The user-reported Doona zoom response is tested at its original encoding. The test also covers the ten gallery assets, two independent pram photos, JPEG thumbnails, occupied strollers and a synthetic scene with two people separated by merchandise. Clear network responses must match the original bytes. A regional patch on each labeled positive checks that the actual person was covered.

The COCO128-seg sample comes from the [Ultralytics dataset release](https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128-seg.zip). Class 0 polygons provide a person reference on 128 images. Pixel precision is the fraction of masked pixels inside a labeled person. Pixel recall is the fraction of annotated person pixels covered. These are regression measurements on a fixed sample, with incomplete labels possible. The sample includes COCO training images and cannot establish performance on unseen photos. Test photos and labels are never included in the app or requested during filtering.

The build verifies Apple’s Core ML versions of YOLOv3 (8-bit LUT) and DeepLabV3 (FP16). The app also bundles a 218 KB Core ML conversion of the [OpenCV Zoo YuNet face detector](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet). Its MIT notice and reproducible conversion script are in this repository. All three models run on the Mac.

The worker accepts YOLO detections whose top class is person. It tests connected person-class pixels against independent body, face or hand evidence at the same location. A five-landmark face can fill a local oval where segmentation missed part of the face if a second detector or a matching person matte confirms the location. For an unresolved face, it checks only overlapping crops containing that face. In silhouette mode, parts of an already confirmed person extending past the body box can be restored where both pixel models agree. Nearby people retain separate bounds in rectangle mode. The Activity detail and single-request export include the recognition summary for fresh and cached decisions.

CI builds the pinned preview 145 worker and scores it on the same runner, images and annotations as the candidate. The candidate must clear every empty-product fixture, retain the marked person regions and leave merchandise between people untouched. On the COCO sample it must identify at least as many person-containing images as the control, make at most six false image decisions on negatives, achieve at least 72% person-pixel precision and stay within 2.5 percentage points of the control’s person-pixel recall. A byte-identical replay of the original zoom response is tested through the proxy.
