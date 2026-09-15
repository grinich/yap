# Meeting chat

Yap exposes the chat features implemented by the installed macOS Meeting SDK 7.1.5 public API:

- Send to Everyone, an individual participant, All Panelists, or the Waiting Room when the current meeting role and chat policy allow that audience. Recipient labels distinguish private messages and waiting-room messages. The attendee-and-copied-panelists webinar audience has a distinct label and no reply action; it is never labeled private.
- Reply in supported threads; a direct message without thread support can receive a new private reply. Each reply derives its audience from the original message again at send time. A missing original message, departed recipient, unknown audience, or revoked permission rejects the send. It never becomes an Everyone message.
- Compose bold, italic, underlined, struck-through text and links. The native editor supports selected-text formatting, mixed styles, supported pasted RTF styles, Unicode, Command-B/I/U, Return to send, and Shift-Return for a newline. IME confirmation does not send a message. SDK builder ranges use NSString offsets; `Scripts/test-chat-content.sh` checks emitted builder calls with an emoji next to an independently styled ASCII run. The offline builder does not populate received-message formatting getters, so that test cannot prove live formatting interoperability.
- Delete your own messages when Zoom reports deletion is allowed. Incoming edits and deletions from other Zoom clients continue to update the transcript.
- Send files to Everyone or a private recipient, within Zoom’s allowed types and size limit. Incoming attachments require an explicit Save action. Sending/receiving progress, failures, and cancellation are shown. Failed or cancelled downloads can request another attempt through the session’s retained SDK receiver; an SDK refusal remains an error and does not claim a restarted download. File-save and send dialogs capture the original meeting session and recipient; a later meeting cannot inherit the action.
- Search received messages, names, recipient labels and attachments; export the retained chat as UTF-8 plain text, with timestamps, audiences, thread labels and file metadata. Export describes the history currently retained in Yap; it does not claim to be the complete server history. Existing reply expansion, copy/quote actions, message toasts, unread badges and notification sounds remain.

## Public SDK limits

**Editing a sent message:** the macOS public API offers `onChatMessageEditNotification:` to receive an edit, but no command to edit an existing sent message. `ZoomSDKChatMsgInfoBuilder` builds a new message; resending corrected text is not an edit. Yap therefore does not expose a misleading Edit command.

**Per-message emoji reactions:** neither `ZoomSDKMeetingChatController` nor `ZoomSDKMeetingActionController` offers a chat-message reaction command or a message-reaction callback. `ZoomSDKReactionController` sends meeting-wide reactions and feedback; it is not a chat-message reaction API. Yap does not simulate message reactions locally.

These limits were checked against the installed public headers and the current official references on September 14, 2026:

- [Chat controller: messages and file transfer](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_meeting_chat_controller.html)
- [Chat delegate: incoming messages, edits, and file progress](https://marketplacefront.zoom.us/sdk/meeting/macos/protocol_zoom_s_d_k_meeting_chat_controller_delegate-p.html)
- [Message builder: recipients, threads, and rich text](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_chat_msg_info_builder.html)
- [Meeting action controller: message deletion and chat policy](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_meeting_action_controller.html)
- [Reaction controller: meeting reactions](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_reaction_controller.html)

## Verification

`AdvancedMeetingChatTests` covers private-reply routing, stale sessions, deleted parents, departed recipients, host-only policies, waiting-room selection, own-message deletion, attachment state updates, file validation and audience labels. `MeetingChatAdvancedUITests` covers formatting/Unicode, mixed traits, safe links, private thread isolation, search/export, and draft reset. Native `ChatContentTests` exercises actual SDK content construction, style-call ranges, audience mapping and JSON boolean types without joining a meeting or sending a message. The integrated interface preview has public/private/threaded/formatted messages, waiting-room options, file progress/failure fixtures and permission changes. Live interoperability requires a separately authorized test meeting; fixture success is not evidence of delivery to real Zoom recipients.
