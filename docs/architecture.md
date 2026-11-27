# Current architecture

Audit a release by recording its Git tag and downloading the matching source. The proxy app and the imported-photo editor are separate projects. This repository builds the proxy.

| Component | Responsibility |
| --- | --- |
| Sources/App.swift and Interface.swift | App lifecycle, preferences, worker supervision, Activity table and user-initiated exports |
| Sources/NetworkSetup.swift | HTTPS probe, local certificate trust, system proxy setup and restoration |
| proxy/policy.py and admission.py | Destination selection for PAC, TLS and HTTP, plus reservations for concurrent image bodies |
| proxy/filter.py | Image eligibility, HTTP content decoding, result cache, request-scoped settings, worker IPC and response selection |
| Sources/Mask.swift | ImageIO decode, Vision or Core ML segmentation, localized fallback, Core Image composition and PNG output |
| proxy/journal.py | Bounded in-memory event retention and filtered JSON or ZIP responses through the authenticated loopback endpoint |
| Sources/Updates.swift and install-update.sh | Check GitHub, verify asset, stage the replacement and relaunch |
| build.sh, tests/ and .github/workflows/verify.yml | Package the runtime and model, test HTTPS and Chrome rendering on macOS, and publish the winning runner’s ZIP |

## Interpreting Activity

Total milliseconds run from proxy request headers to the recorded decision or transport error. A block at response headers ends there. Browser decoding, display, and client delivery after the decision are outside this interval. Non-image pass-through successes do not create image decisions.

Stages are elapsed wall time rounded to milliseconds. Absent fields mean the stage was skipped or did not finish. A cache hit can therefore have no worker time.

| Field | Interval |
| --- | --- |
| waitHeadersMS, receiveBodyMS | Request start to origin response headers, then headers to the complete buffered image |
| prepareMS, hashMS, queueMS | Decode HTTP content encoding, validate and snapshot settings, then hash input and wait for the serialized worker |
| workerMS | Worker startup if needed, IPC, native processing and result transfer combined |
| decodeMS, segmentationMS, maskBoundsMS, fallbackMS | Within worker time, prepare the oriented thumbnail, run the primary detector, inspect the mask, and optionally run rescue detectors |
| composeGraphMS, renderEncodeMS | Within worker time, construct the Core Image graph, then execute it and encode the output |

Worker stages are nested within workerMS. Adding every number double-counts that interval. For a transport error before an HTTP response, status 0 means no downstream HTTP status was available. Origin metadata is recorded only if response headers reached image classification. Error text can contain host or system details. Review exported metadata before sharing.

The ZIP contains manifest.json with one entry per matching event and mask-settings.json with settings keyed by event ID when available. Metadata-only capture does not retain image payloads in the journal. Processing and the in-memory result cache still require image bytes. Exporting metadata alone also omits image files from sessions that retained them.
