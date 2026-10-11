# AI Glasses Link for iOS

Phase 2 phone-offload proof: an iPhone receives camera and thermal data directly from an ESP32-S3 over a local WebSocket connection. The app intentionally does not include audio, perception, cloud forwarding, session controls, or settings.

## Requirements

- Xcode 16 or newer
- iPhone running iOS 17 or newer
- An Apple development team for device signing
- iPhone and ESP32 connected to the same Wi-Fi network

The project has no third-party dependencies. It uses Apple's `Network.framework` as the WebSocket server. The iOS Simulator is useful for compilation and unit tests, but the ESP32 link must be tested on a physical iPhone because inbound LAN behavior and Local Network privacy authorization need a real device.

## Build and run on an iPhone

1. Open `AIGlassesLink.xcodeproj` in Xcode.
2. Select the **AIGlassesLink** project, then the **AIGlassesLink** app target.
3. Under **Signing & Capabilities**, choose your development team. Change the placeholder bundle identifier `com.example.AIGlassesLink` if your team requires a unique identifier.
4. Select a connected iPhone as the run destination and press Run.
5. Accept the Local Network permission prompt.
6. Keep the app in the foreground. It intentionally stops listening when backgrounded.
7. Copy the WebSocket URL shown in the app into the ESP32 firmware's server configuration.

The default endpoint is:

```text
ws://<iPhone Wi-Fi IPv4 address>:8081/ws/camera_thermal
```

`Network.framework` handles the WebSocket upgrade but does not expose the incoming HTTP request target to server code. `/ws/camera_thermal` is therefore the required documented firmware URL, but the app does not reject upgrades that use a different path.

## Configure the port

Edit the `WebSocketPort` integer in `AIGlassesLink/Info.plist`, then rebuild and reinstall the app. The default is `8081`. There is deliberately no settings screen in this phase.

## Wire protocol

Every item is one complete binary WebSocket message:

```text
[one-byte type discriminator][payload]
```

| Type | Name | Payload | Phase 2 behavior |
| --- | --- | --- | --- |
| `0x01` | CAM | JPEG | Decode and display |
| `0x02` | THERMAL | 3,072 bytes: 768 little-endian Float32 values | Validate, canonicalize, false-colour, display |
| `0x03` | IMU | 32-byte packed firmware struct | Recognize and ignore |
| `0x04` | STATUS | 16-byte packed firmware struct | Recognize and ignore |

Unknown types, empty messages, and incorrect fixed payload sizes are reported in the UI. Valid IMU and STATUS messages are ignored without affecting camera/thermal FPS.

### RGB orientation

The camera sends a 320×240 landscape JPEG because the module is mounted sideways. After decoding, the app rotates the image 90 degrees counter-clockwise at display time, producing the backend-compatible 240×320 portrait view. The JPEG is not re-encoded and no flip is applied.

### Thermal orientation

The incoming thermal payload is a native row-major matrix with 24 rows and 32 columns. The app applies the same canonicalization as the backend:

1. Decode 768 little-endian `Float32` values and reject the frame if any value is NaN or infinite.
2. Reshape to `(24, 32)`.
3. Rotate 90 degrees counter-clockwise.
4. Flip horizontally.

The result has 32 rows and 24 columns and is shown as a separate bottom-right inset. This fixes sensor mounting orientation only. RGB/thermal registration, field-of-view mapping, parallax, and depth calibration are not performed.

## Tests

From Xcode, run **Product → Test**, or use:

```sh
xcodebuild test \
  -project AIGlassesLink.xcodeproj \
  -scheme AIGlassesLink \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The tests cover all four message discriminators, fixed payload lengths, thermal little-endian decoding, the exact orientation transform, non-finite rejection, false-colour rendering, and rolling FPS accounting.

## Device acceptance check

1. Confirm the app says **Listening** and displays the expected Wi-Fi IPv4 address.
2. Point the ESP32 at the displayed URL.
3. Confirm the status changes to **ESP32 connected**.
4. Confirm the 320×240 JPEG feed updates as a counter-clockwise-rotated 240×320 portrait view and CAM FPS is close to the firmware's rate.
5. Confirm the portrait thermal inset updates with the physically correct orientation.
6. Confirm frequent IMU and periodic STATUS traffic do not show errors or change either visual FPS counter.
7. Restart the ESP32 and confirm the app returns to listening, then reconnects.

If the ESP32 cannot connect, verify Local Network permission under **Settings → Privacy & Security → Local Network**, confirm both devices are on the same non-isolated Wi-Fi network, and check that client isolation or a VPN is not blocking peer-to-peer LAN traffic.
