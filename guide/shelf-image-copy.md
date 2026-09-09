# Resize a Copy

In File Shelf's full view, use **Resize a Copy…** beneath a local file. JPEG and PNG content is checked before options appear. Choose a longest edge of 1,024 or 2,048 pixels, review the exact output dimensions, then select **Save Copy…** and choose a new filename in the macOS Save dialog.

Images are never enlarged. The copy keeps its source format, displayed orientation, color profile, and PNG transparency. JPEG output is re-encoded at a fixed quality setting and can lose detail even when its dimensions do not change. The original file is never modified. An existing destination is refused, including the source itself; select a different name to retry.

Camera, location, and descriptive metadata are removed, including source EXIF, GPS, IPTC, XMP, camera notes, and PNG text. Format information needed to render the new image, including its color profile, remains. This does not remove information visible in the pixels.

Resize a Copy accepts one fully downloaded local JPEG or PNG of at most 32 MiB, 40 million pixels, and 16,384 pixels per side. Animated, unsupported, corrupt, unavailable, or larger inputs are refused. It does not download cloud files, watch folders, process batches, upload images, or save a resize history.

Cancel in the Save dialog returns to the size options. Cancel in the size options, Clear Shelf, Pause, source removal or expiry, and Quit cancel and drain owned work. A native image operation may need to finish before cancellation can complete. A successfully published copy belongs to you and is never removed by clearing the shelf. Failed temporary cleanup remains visible and must be retried before another resize.

The implementation uses a bounded source snapshot and bounded output, verifies the encoded image before publishing it, and refuses to overwrite an existing path. ImageIO does not promise a fixed peak memory limit or interruption inside every native call. Native Save-dialog focus, cancellation, and signed-build behavior require the quality task's separate acceptance pass.
