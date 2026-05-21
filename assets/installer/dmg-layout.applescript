-- dmg-layout.applescript — Set DMG Finder window appearance.
-- Called by build-installer.sh after mounting the read-write DMG.
-- Usage: osascript dmg-layout.applescript /Volumes/Hippocampus

on run argv
    set mountPoint to item 1 of argv
    set volName to "Hippocampus"

    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {100, 100, 740, 580}

            set theViewOptions to icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 80
            set text size of theViewOptions to 12
            set background picture of theViewOptions to file ".background:background.png"

            -- Icon positions: app on left, Applications on right
            set position of item "Hippocampus.app" of container window to {190, 260}
            set position of item "Applications" of container window to {450, 260}

            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
