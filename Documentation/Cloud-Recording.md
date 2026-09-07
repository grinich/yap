# Cloud recording

**Historical evidence:** recorded checks in this document predate the Yap rename. References to earlier app identities and original evidence files describe those checkpoints, not validation of the renamed build. See [Bundle Identity](Bundle-Identity.md).

Research and integration contract, September 6, 2026, checked against official Zoom documentation and the bundled macOS Meeting SDK **7.1.5 (84750)** public headers. The implementation and real Start/Pause/Resume/Stop sequence are now verified in the installed app; processed-file playback remains unverified. See the [live verification record](../../outputs/Whoosh-Cloud-Recording-Verification.md).

## Requirements and authority

Cloud recording requires an eligible licensed host on a Pro, Business, or Enterprise account, cloud recording enabled, and available account capacity. Account/group settings can restrict availability. Only the host or a co-host can start cloud recording; recordings started by a co-host belong to the host's recording list. End-to-end encrypted meetings disable cloud recording. Recheck the SDK's capability result instead of inferring availability from Yap sign-in or the visible role alone. [Zoom requirements](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0062627), [account settings](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0063923), [E2EE limitations](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0065408).

## Meeting SDK control contract

Obtain `ZoomSDKMeetingService.getRecordController` for the current meeting. The checked `ZoomSDKMeetingRecordController.h` exposes:

| Action | API |
|---|---|
| Check cloud eligibility | `canStartRecording:YES` — success is `ZoomSDKError_Success`, not a Boolean |
| Start / stop | `startCloudRecording:YES` / `startCloudRecording:NO` |
| Pause / resume | `pauseCloudRecording` / `resumeCloudRecording` |
| Read current state | `getCloudRecordingStatus` |
| Observe state / privilege | `onCloudRecordingStatus:` / `onRecordPrivilegeChange:` |
| Observe storage limit | `onCloudRecordingStorageFull:` |

States include None, Connecting, Start, Pause, Stop, DiskFull, and Fail. Use callbacks/getter state for the indicator; a successful command return alone does not prove recording or a completed file. Keep commands scoped to the current connected meeting and refresh availability when authority changes. [Controller reference](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_meeting_record_controller.html).

These are **in-meeting SDK commands and require no new REST OAuth scopes**. They use the existing authenticated meeting identity and recording privileges. This distinction does not waive account eligibility, SDK authorization, or participant consent. File retrieval is a separate future API integration.

Pause/resume continues the same recording; stopping and starting again creates another recording file. Stop is not Delete, and processing may continue after the meeting. Show “stopped” separately from “ready to view.” [Zoom recording lifecycle](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0062627).

## Consent and notices

Preserve Zoom's recording notification/consent flow, including participants joining an already recorded meeting. The account can customize which participants receive notices. Render SDK-supplied reminder content and respond to the person's decision through `onReminderNotify:reminderContent:` and `ZoomSDKReminderHandler.accept`/`decline`; do not auto-accept or hide recording disclaimers. Keep an accessible recording/paused indicator and refresh the existing SDK-provided recorded-chat legal notice. [Recording consent](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0059819), [reminder handler](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_reminder_handler.html), [mandatory UI notices](https://developers.zoom.us/docs/meeting-sdk/ui-notices/).

Basic cloud recording must not silently enable smart recording or future-meeting settings. If the SDK supplies a smart-recording request handler, its public header provides `startCloudRecordingWithoutEnableSmartRecording` as a distinct action.

## After the meeting

The host can use Zoom's Recordings & Transcripts portal once processing finishes; optional email notifications depend on account settings. This is the initial retrieval route. [Manage recordings](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0067567).

A future Yap recording browser would separately request `cloud_recording:read:list_recording_files` for `GET /meetings/{meetingId}/recordings`, or `cloud_recording:read:list_user_recordings` for a user's list, with new consent as needed. A future `recording.completed` webhook also needs its own subscription, endpoint, and `cloud_recording:read:recording` scope. Processing completion, ownership, download authorization, and sharing access must be checked before offering files. None of those retrieval capabilities or scopes are implied by the SDK recording controls. [Recording API](https://developers.zoom.us/docs/api/meetings/), [granular scopes](https://developers.zoom.us/docs/integrations/oauth-scopes-granular/), [webhook requirements](https://developers.zoom.us/docs/api/webhooks/).
