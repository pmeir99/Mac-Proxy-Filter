# Image Filtration — standalone photo editor

This directory contains a standalone Apple silicon editor for photos you import. For current work on the imported-image app, see [Image-Filtration-V1](https://github.com/pmeir99/Image-Filtration-V1). For website filtering, setup, and diagnostics, see the [Mac Proxy Filter README](../README.md).

## Use this snapshot

1. Open or drop an image into **Image Filtration**. The app uses Apple Vision to identify foreground subjects. It shows a description using Apple Intelligence when available, with Vision labels as a fallback.
2. Click a detected subject and choose blur, pixelation, or solid fill. Selection is limited to the foreground instances Vision found.
3. Export the edited image as a full-size PNG. Image processing runs locally.

## Build and updates

The [editor workflow](../.github/workflows/image-editor.yml) targets Apple silicon and macOS 27, builds an ad-hoc-signed app, and packages it as `Image-Filtration-macOS-arm64.zip`. A tag such as `image-editor-v0.1.0` publishes an editor release. In this snapshot, **Image Filtration → Check for Updates…** opens the GitHub release page when a newer stable editor version is available. Install that download manually.
