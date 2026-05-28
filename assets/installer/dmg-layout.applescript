-- dmg-layout.applescript — Set DMG Finder window appearance.
-- Called by build-installer.sh after mounting the read-write DMG.
-- Window: 720x460 (1x coords); background.png is 1280x800.
-- Usage: osascript dmg-layout.applescript /Volumes/Hippocampus
--
-- Pattern adopted from Raycast / Granola DMGs (both ship 10244-byte .DS_Store
-- with positioned drag-to-Applications layout). Key persistence tricks:
--   - Volume name is *derived from the mount path*, not hardcoded. If an
--     older /Volumes/Hippocampus is still mounted, macOS attaches the new
--     image as "Hippocampus 1"; targeting `disk "Hippocampus"` would write
--     the layout to the wrong volume and our final DMG would ship empty.
--   - Use POSIX-file alias for the background image (HFS-colon paths are
--     flaky on modern macOS).
--   - Double `update without registering applications` so Finder commits.
--   - Generous delays + final `sync` shell-out so .DS_Store hits the HFS
--     journal before the caller detaches the image.
on run argv
    set mountPoint to item 1 of argv

    -- Derive the volume name from the mount path (handles "Hippocampus 1"
    -- collision case described above).
    set AppleScript's text item delimiters to "/"
    set pathParts to text items of mountPoint
    set volName to last item of pathParts
    set AppleScript's text item delimiters to ""

    -- Resolve absolute POSIX path to the background image, then convert
    -- to an AppleScript alias.
    set bgPosixPath to mountPoint & "/.background/background.png"
    set bgAlias to POSIX file bgPosixPath as alias

    tell application "Finder"
        tell disk volName
            open

            -- View chrome
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            try
                set sidebar width of container window to 0
            end try

            -- Window geometry: 720x460 centered area on background
            set bounds of container window to {200, 200, 920, 660}

            -- Icon-view options
            set theViewOptions to icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 96
            set text size of theViewOptions to 12
            try
                set shows item info of theViewOptions to false
            end try
            try
                set shows icon preview of theViewOptions to false
            end try
            set background picture of theViewOptions to bgAlias

            -- Icon positions: app on left, Applications on right.
            set position of item "Hippocampus.app" of container window to {200, 250}
            set position of item "Applications" of container window to {520, 250}

            -- First commit: forces Finder to write the layout.
            update without registering applications
            delay 2

            -- Second commit: some Finder builds only persist after a
            -- second `update` once the icon-view options have rendered.
            update without registering applications
            delay 1

            close
        end tell

        -- Belt-and-braces: ensure Finder finishes any pending writes
        -- before the shell detach runs.
        delay 2
    end tell

    -- Force a filesystem sync so the .DS_Store hits the HFS journal
    -- before `hdiutil detach` releases the volume.
    do shell script "sync; sync; sync"
end run
