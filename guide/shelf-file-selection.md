# Add files to File Shelf

Use **Choose Files…** in either the compact File Shelf card or its detail window. With that view active, **Command-O** opens the same native file picker. Start File Shelf first if it is paused.

Select one or more files or folders, then choose **Add to Shelf**. File Shelf keeps references to those items. Originals stay in place, and selecting a folder does not copy its contents. The shelf holds up to 100 items; a selection that exceeds the remaining space is rejected before any of its items are added.

Choose **Cancel** in the picker to leave the shelf unchanged. Once a selection starts importing, **Cancel Import** stops the remaining items; references already added stay on the shelf. Pause, Clear Shelf, and quitting also cancel pending selection and wait for it to finish. Clear Shelf removes shelf references, not the original files.

macOS can refuse access to a selected item. File Shelf reports failures and shows the state of unavailable references. Check access in Finder, then choose the item again if needed. Cloud-only items are not downloaded by File Shelf; download them in Finder before using file actions, then refresh the shelf.

**Keep shelf between launches** is off by default. When enabled, eligible file references use local bookmarks; the selected files are still not copied.

## Native acceptance pending

Automated logic tests cover selection, references, bookmarks, capacity, cancellation, and lifecycle draining. Native dialog focus, cancellation, keyboard navigation, and Command-O routing between compact and detail views still require the quality manager's desktop acceptance pass.
