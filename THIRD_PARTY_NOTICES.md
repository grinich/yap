# Third-party components

## Zoom Meeting SDK

Zooom integrates the proprietary Zoom Meeting SDK for macOS. The SDK is obtained separately from Zoom and is not included in this source repository. Its use and redistribution are governed by [Zoom's API License and Terms of Use](https://www.zoom.com/en/trust/legal/zoom-api-license-and-tou/) and the SDK's accompanying notices. A license for Zooom's own code does not grant rights to Zoom's SDK, trademarks, or service.

Signed app bundles include the SDK's supplied open-source notices at `Contents/Resources/ThirdPartyLicenses/Zoom-OSS-LICENSE.pdf`. That notice is not a substitute for Zoom's SDK terms or distribution approval. The release workflow retrieves the original SDK archive only from a separately configured private dependency repository.

## Sparkle

Zooom uses [Sparkle](https://sparkle-project.org/) for macOS application updates. The pinned version is recorded in `Package.resolved`. Sparkle is distributed under its MIT license and includes additional component notices. The complete notice from the resolved upstream distribution is copied without modification to `Contents/Resources/ThirdPartyLicenses/Sparkle.txt` in built app bundles.

See [Sparkle's upstream license](https://github.com/sparkle-project/Sparkle/blob/2.9.6/LICENSE).

## Apple frameworks

The app uses system frameworks including SwiftUI, AppKit, AVFoundation, Security, and App Intents. These are provided by Apple and are subject to Apple's terms.
