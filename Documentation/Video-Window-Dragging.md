# Move the meeting window from its video

In a solo meeting, one-to-one call, or focused/active-speaker layout, dragging the camera image or camera-off avatar canvas moves the meeting window. The self-view and focused layout's participant strip support the same interaction. A transparent AppKit surface calls the owning window's native `performDrag(with:)`; it does not resize or recreate the renderer.

Call controls, header buttons, menus, Chat, and People are layered above the drag surface and retain their normal interactions. Secondary/control-clicks pass through to the participant context menu. Gallery tiles retain drag-to-reorder, and shared-screen interaction is unchanged. Full-screen windows and windows temporarily locked by a native menu do not begin a move.

Native tests check the primary drag dispatch, owning-window movability, and detached/secondary-click handling. The signed build is staged separately while the current meeting runs; actual installed pointer dragging remains to be verified after installation.
