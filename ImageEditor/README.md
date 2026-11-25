# Image Filtration

A native photo editor for Apple Silicon Macs running macOS 27. Open or drop an image, read its description, and click a detected foreground subject to apply blur, pixelation, or a solid fill. Export creates a full-size PNG. Apple Intelligence supplies captions when available, with Vision labels as a fallback. Image processing runs locally.

The workflow builds an ad-hoc-signed app ZIP. A version tag such as `image-editor-v0.1.0` publishes the ZIP to GitHub Releases. **Image Filtration → Check for Updates…** checks the latest stable image editor release and opens its GitHub page when an update is available. Install the downloaded app manually.

The editor currently selects foreground instances using Apple Vision. Point-guided selection for additional objects is pending.
