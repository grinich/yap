# Camera effects

Open **Yap → Settings → Camera** to choose **None**, **Blur**, or a photo background, and turn **Automatically frame me** on or off. **Preview camera** starts a local Zoom preview without joining a meeting. Closing Camera settings stops that preview. During a meeting, use your meeting self-view to check changes; the separate settings preview stays off. Effects are applied to the outgoing camera through the Zoom Meeting SDK.

Photos are copied into Yap’s application support folder, so moving the original photo does not break the background. PNG, JPEG, HEIC, and TIFF files up to 32 MB are accepted and normalized to a PNG with a maximum dimension of 3840 pixels. The original file is never changed.

Yap saves a selection only after Zoom confirms it. Saved effects are restored before the camera is enabled in a meeting. If an effect is unavailable or a photo cannot be found, the camera remains off and Camera settings offers recovery. Availability depends on the connected camera, computer, and Zoom account settings.

Implementation uses the bundled Zoom Meeting SDK 7.1.5: the virtual background settings APIs, face-recognition auto-framing, and the SDK camera-test helper. Settings authorization requests an SDK signature, without fetching a ZAK or joining/creating a meeting. The settings session shares the process-wide SDK owner with meeting connections.

Validation commands:

- `swift test --arch arm64 --disable-sandbox` with `YAP_ZOOM_SDK_PATH` configured.
- `Scripts/test-camera-effects.sh` with the same SDK path; its SDK substitutes exercise effect confirmation and preview/meeting lifecycle without capturing camera video or joining a call.
