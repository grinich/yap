# Portrait video layout

Zoom's macOS Meeting SDK supplies each camera stream’s dimensions through [`getUserVideoSize:`](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_meeting_service.html). Zooom previously placed every gallery participant into a 16:9 tile; a phone held vertically was therefore letterboxed inside that wide tile.

The gallery now retains each camera feed’s aspect ratio. Rows use individual tile widths, and portrait rows can grow taller in a narrow window. Camera-off avatars and streams whose dimensions are not yet available retain the usual 16:9 shape. Focus and received-share thumbnail strips also use the source aspect ratio. The native video renderer and subscription handoff remain unchanged; screen-share content is not cropped.

Roster and renderer callbacks refresh dimensions. Since the native renderer exposes no dimension-change callback, a 500 ms timer checks only subscribed streams for rotation, emitting a roster update only when dimensions change. Temporary zero or invalid sizes retain the last valid geometry. Camera-off, participant departure, and meeting cleanup clear cached dimensions.

Validation: gallery tests cover mixed portrait, landscape and square feeds through 101 participants at narrow and wide sizes, incomplete rows, invalid sizes and bounds. An Objective-C fixture against the compiled Zoom bridge verifies portrait dimensions, rotation, stable polling, invalid values, camera-off and participant ID reuse. A native synthetic renderer visually verified the full portrait frame at 320×750 and its transition to landscape. Actual remote-phone rotation in a live Zoom call remains an acceptance check.
