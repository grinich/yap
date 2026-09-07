# Meeting layouts

The Meeting Layout menu offers **Gallery View** and **Active Speaker**. Gallery keeps the existing people-per-page choices (25, 49, 100 and Show all) and incoming video aspect ratios. Active Speaker shows a large participant with up to six other participants in the thumbnail strip. It follows speaking participants from the full meeting roster, including people outside the previous gallery page.

One-to-one calls automatically show the other participant edge-to-edge, with a small self-view in the upper-right corner. Both streams stay subscribed. The self-view remains visible when the call controls fade, displays an avatar when the camera is off, and leaves room for the toolbar and an open inspector. A third participant restores the selected group layout. Explicitly pinning self and viewing a received screen share take precedence.

The active speaker stays visible during silence and overlapping speech until another participant is the speaker. Other participants are preferred over self while they are present; a solo meeting displays self. Camera-off participants remain eligible and display their avatar.

Pinning a participant temporarily overrides automatic following. Unpinning resumes the current speaker. Choosing a layout clears a pin and returns from shared content to people. Participant departure clears invalid pins and picks a fallback; ending a meeting clears speaker identity and pins while preserving the selected layout for the next meeting.

The coordinator keeps native subscriptions aligned with the visible large tile and strip. This avoids subscribing an entire gallery page to display only a handful of videos. Gallery selections retain their configured page limit.

In Gallery View, drag a tile onto another tile to move it to that slot. The tile follows the pointer, the destination is outlined in blue, and the remaining tiles animate into their new positions on release. Dropping in empty space leaves the order unchanged. The context menu and VoiceOver actions also offer Move earlier and Move later within the visible page. The tile gesture does not move the meeting window.

Custom gallery order is local to the current meeting. Media updates, paging, pins and switching to Active Speaker and back preserve it; newcomers append, departed participants are removed, and a new meeting starts with the provider's order. Reordering never changes Zoom's roster or other attendees' layouts. Stale drags are rejected after a meeting ends.

Validation includes coordinator tests for switching modes, off-page speakers, pauses, overlap, muted/local speech, pins, participant departure and session isolation. One-to-one tests cover both subscriptions, roster transitions, self pins, received shares and incomplete rosters; geometry tests cover compact/portrait windows and incoming video aspect ratios. The native inert preview verifies both menu choices, Gallery → Active Speaker, a change between two simulated speakers, and Active Speaker → Gallery. Self-view checks use separate synthetic native video surfaces. Live audio-driven switching remains a live-call acceptance check.
