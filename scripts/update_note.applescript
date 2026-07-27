on run argv
    if (count of argv) is less than 1 then error "Usage: update_note.applescript <html-file>"

    set htmlPath to item 1 of argv
    set htmlBody to read POSIX file htmlPath as «class utf8»
    set targetAccountName to "iCloud"
    set targetFolderName to "Gmail 日报"
    set targetNoteName to "Gmail 日报"

    tell application "Notes"
        if not (exists account targetAccountName) then error "Notes account not found: " & targetAccountName
        set targetAccount to account targetAccountName

        if exists folder targetFolderName of targetAccount then
            set targetFolder to folder targetFolderName of targetAccount
        else
            set targetFolder to make new folder at targetAccount with properties {name:targetFolderName}
        end if

        set matchingNotes to every note of targetFolder whose name is targetNoteName
        if (count of matchingNotes) is 0 then
            set targetNote to make new note at targetFolder with properties {name:targetNoteName, body:htmlBody}
        else
            set targetNote to item 1 of matchingNotes
            set body of targetNote to htmlBody
            set name of targetNote to targetNoteName
        end if

        return id of targetNote
    end tell
end run
