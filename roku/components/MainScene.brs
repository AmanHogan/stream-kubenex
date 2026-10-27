' Watch state lives on the server (/api/progress, /api/watched). This scene
' reports the position while a video plays and reloads the library afterwards,
' so the progress bars, Continue Watching and Watched badges stay current.

sub init()
    m.rows = m.top.findNode("rows")
    m.showScreen = m.top.findNode("showScreen")
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.skip = m.top.findNode("skipIntro")
    m.skipButton = m.top.findNode("skipButton")
    m.upNext = m.top.findNode("upNext")
    m.upNextTitle = m.top.findNode("upNextTitle")
    m.upNextCount = m.top.findNode("upNextCount")
    m.upNextButton = m.top.findNode("upNextButton")
    m.countdown = m.top.findNode("countdown")
    m.dialog = m.top.findNode("dialog")

    m.rows.observeField("rowItemSelected", "onRowItemSelected")
    m.showScreen.observeField("selectedVideoId", "onShowVideoSelected")
    m.showScreen.observeField("menuRequest", "onShowMenu")
    m.showScreen.observeField("closed", "onShowClosed")
    m.video.observeField("state", "onVideoState")
    m.video.observeField("position", "onVideoPosition")
    m.skipButton.observeField("buttonSelected", "onSkipPressed")
    m.upNextButton.observeField("buttonSelected", "playNext")
    m.countdown.observeField("fire", "onCountdown")
    m.dialog.observeField("selected", "onDialogSelected")
    m.dialog.observeField("cancelled", "onDialogCancelled")

    m.api = CreateObject("roSGNode", "ApiTask")
    m.api.observeField("completed", "onApiCompleted")
    m.api.control = "run"
    m.inFlight = 0
    m.pendingReload = false

    m.library = invalid
    m.videos = {}
    m.current = invalid     ' the video playing now (an entry of m.videos)
    m.choices = []
    m.top.setFocus(true)
    loadLibrary()
end sub

' --- library ------------------------------------------------------------------

sub loadLibrary()
    if m.library = invalid then m.status.text = "Loading..."
    ' Network calls must run in a Task node, never on the render thread.
    m.task = CreateObject("roSGNode", "LibraryTask")
    m.task.observeField("rows", "onLibraryLoaded")
    m.task.observeField("error", "onLibraryError")
    m.task.control = "run"
end sub

sub onLibraryLoaded()
    m.library = m.task.library
    m.videos = m.task.videos
    focused = m.rows.rowItemFocused
    m.rows.content = m.task.rows
    rowCount = m.task.rows.getChildCount()
    if rowCount = 0
        m.status.text = "No videos yet. Add one from the web form, then press * and Refresh."
        return
    end if
    m.status.text = "OK opens or plays  -  * for more"
    ' Keep the place on the home screen after a refresh.
    if focused <> invalid and focused.Count() = 2 and focused[0] < rowCount
        row = m.task.rows.getChild(focused[0])
        if focused[1] < row.getChildCount() then m.rows.jumpToRowItem = focused
    end if
    ' A refresh while a show is open updates that show in place.
    if m.showScreen.visible
        for each s in m.library.shows
            if s.name = m.showScreen.show.name then m.showScreen.show = s
        end for
    end if
    if not m.showScreen.visible and not m.video.visible and not m.dialog.visible then m.rows.setFocus(true)
end sub

sub onLibraryError()
    m.status.text = "Cannot load library: " + m.task.error + "  -  press * to retry"
end sub

' --- server updates -----------------------------------------------------------

sub send(path as String, body as Object)
    m.inFlight = m.inFlight + 1
    m.api.request = { path: path, body: body }
end sub

' Reload once every queued update has reached the server, so the screen shows it.
sub reloadAfterUpdates()
    if m.inFlight <= 0
        loadLibrary()
    else
        m.pendingReload = true
    end if
end sub

sub onApiCompleted()
    m.inFlight = m.inFlight - 1
    if m.inFlight <= 0 and m.pendingReload
        m.pendingReload = false
        loadLibrary()
    end if
end sub

sub saveProgress(seconds as Integer)
    if m.current = invalid then return
    m.lastSaved = seconds
    send("/api/progress/" + m.current.id, { position: seconds })
end sub

sub setWatched(ids as Object, watched as Boolean)
    send("/api/watched", { ids: ids, watched: watched })
    reloadAfterUpdates()
end sub

' --- choosing what to play -----------------------------------------------------

sub onRowItemSelected()
    sel = m.rows.rowItemSelected
    item = m.rows.content.getChild(sel[0]).getChild(sel[1])
    if item.itemType = "show"
        m.showScreen.show = m.library.shows[item.showIndex]
    else
        selectVideo(m.videos[item.videoId])
    end if
end sub

sub onShowVideoSelected()
    selectVideo(m.videos[m.showScreen.selectedVideoId])
end sub

sub onShowClosed()
    m.rows.setFocus(true)
end sub

' Part-watched: ask Resume or Start over. Otherwise play from the top.
sub selectVideo(v as Dynamic)
    if v = invalid then return
    position = intOr(v.position, 0)
    if position > 0
        showMenu("Resume " + episodeLabel(v) + "?", [
            { label: "Resume from " + formatDuration(position), action: "play", video: v, start: position },
            { label: "Play from beginning", action: "play", video: v, start: 0 }
        ])
    else
        play(v, 0)
    end if
end sub

' --- player -------------------------------------------------------------------

sub play(v as Object, start as Integer)
    if m.current <> invalid then saveProgress(Int(m.video.position))
    content = CreateObject("roSGNode", "ContentNode")
    content.url = v.url
    content.title = v.title
    content.streamFormat = "mp4"
    if start > 0 then content.PlayStart = start
    m.current = v
    m.lastSaved = start
    m.skipDismissed = false
    m.upNextState = "none"    ' none | showing | dismissed
    hideOverlays()
    m.video.content = content
    m.video.visible = true
    m.video.setFocus(true)
    m.video.control = "play"
end sub

sub onVideoPosition()
    v = m.current
    if v = invalid then return
    seconds = Int(m.video.position)
    if Abs(seconds - m.lastSaved) >= 15 then saveProgress(seconds)

    ' Skip intro, while inside the intro.
    inIntro = v.intro_start <> invalid and v.intro_end <> invalid and seconds >= v.intro_start and seconds < v.intro_end - 1
    if inIntro and not m.skipDismissed and not m.skip.visible and not m.upNext.visible and not m.dialog.visible
        m.skip.visible = true
        m.skipButton.setFocus(true)
    else if not inIntro and m.skip.visible
        hideSkip()
    end if

    ' Credits reached: the server marks it watched; offer the next episode.
    if v.credits_at <> invalid and seconds >= v.credits_at and m.upNextState = "none"
        saveProgress(seconds)
        if v.next_id <> invalid and m.videos.DoesExist(v.next_id) and not m.dialog.visible
            showUpNext()
        else
            m.upNextState = "dismissed"
        end if
    end if
end sub

sub onSkipPressed()
    m.skipDismissed = true
    m.video.seek = m.current.intro_end
    hideSkip()
end sub

sub hideSkip()
    focused = m.skipButton.hasFocus()
    m.skip.visible = false
    if focused then m.video.setFocus(true)
end sub

sub showUpNext()
    m.upNextState = "showing"
    m.upNextTitle.text = "Up next: " + episodeLabel(m.videos[m.current.next_id])
    m.countdownLeft = 10
    updateCountdownText()
    hideSkip()
    m.upNext.visible = true
    m.upNextButton.setFocus(true)
    m.countdown.control = "start"
end sub

sub updateCountdownText()
    m.upNextCount.text = "Starting in " + m.countdownLeft.ToStr() + " seconds  -  Back keeps watching"
end sub

sub onCountdown()
    m.countdownLeft = m.countdownLeft - 1
    if m.countdownLeft <= 0
        playNext()
    else
        updateCountdownText()
    end if
end sub

sub dismissUpNext()
    m.countdown.control = "stop"
    m.upNext.visible = false
    m.upNextState = "dismissed"
    m.video.setFocus(true)
end sub

sub playNext()
    m.countdown.control = "stop"
    m.upNext.visible = false
    if m.current = invalid or m.current.next_id = invalid then return
    nxt = m.videos[m.current.next_id]
    if nxt = invalid then return
    ' A part-watched next episode carries on where it stopped.
    start = 0
    if nxt.watched <> true then start = intOr(nxt.position, 0)
    play(nxt, start)
end sub

sub hideOverlays()
    m.countdown.control = "stop"
    m.skip.visible = false
    m.upNext.visible = false
end sub

sub onVideoState()
    state = m.video.state
    if state = "error"
        m.status.text = "Playback error: " + m.video.errorMsg
        closeVideo()
    else if state = "finished"
        if m.current <> invalid then saveProgress(intOr(m.current.duration, Int(m.video.position)))
        hasNext = m.current <> invalid and m.current.next_id <> invalid and m.videos.DoesExist(m.current.next_id)
        if hasNext and m.upNextState <> "dismissed"
            playNext()
        else
            closeVideo()
        end if
    end if
end sub

sub closeVideo()
    if m.current <> invalid and m.video.state <> "finished" then saveProgress(Int(m.video.position))
    m.current = invalid
    hideOverlays()
    m.video.control = "stop"
    m.video.visible = false
    restoreFocus()
    reloadAfterUpdates()
end sub

' --- menus ----------------------------------------------------------------------
' Each choice is { label, action, ... }; runChoice() acts on the one picked.

sub showMenu(title as String, choices as Object)
    m.choices = choices
    labels = []
    for each c in choices
        labels.Push(c.label)
    end for
    m.dialog.title = title
    m.dialog.options = labels
    m.dialog.callFunc("open", {})
end sub

sub onDialogSelected()
    runChoice(m.choices[m.dialog.selected])
end sub

sub onDialogCancelled()
    if m.video.visible and m.video.state = "paused" then m.video.control = "resume"
    restoreFocus()
end sub

sub runChoice(c as Object)
    if c.action = "play"
        play(c.video, c.start)
    else if c.action = "watched"
        setWatched(c.ids, c.watched)
        restoreFocus()
    else if c.action = "next" or c.action = "previous"
        play(m.videos[c.id], 0)
    else if c.action = "startover"
        m.video.seek = 0
        m.video.control = "resume"
        m.video.setFocus(true)
    else if c.action = "refresh"
        loadLibrary()
        restoreFocus()
    end if
end sub

sub restoreFocus()
    if m.video.visible
        m.video.setFocus(true)
    else if m.showScreen.visible
        m.showScreen.callFunc("restoreFocus", {})
    else if m.rows.content <> invalid and m.rows.content.getChildCount() > 0
        m.rows.setFocus(true)
    else
        m.top.setFocus(true)
    end if
end sub

' Choices for one video: resume or start over, then watched / unwatched.
function videoChoices(v as Object) as Object
    choices = []
    position = intOr(v.position, 0)
    if position > 0 then choices.Push({ label: "Resume from " + formatDuration(position), action: "play", video: v, start: position })
    choices.Push({ label: "Play from beginning", action: "play", video: v, start: 0 })
    if v.watched = true
        choices.Push({ label: "Mark as not watched", action: "watched", ids: [v.id], watched: false })
    else
        choices.Push({ label: "Mark as watched", action: "watched", ids: [v.id], watched: true })
    end if
    return choices
end function

sub openHomeMenu()
    choices = []
    title = "Library"
    sel = m.rows.rowItemFocused
    if m.rows.content <> invalid and sel <> invalid and sel.Count() = 2 and sel[0] >= 0
        item = m.rows.content.getChild(sel[0]).getChild(sel[1])
        if item <> invalid and item.itemType = "show"
            show = m.library.shows[item.showIndex]
            ids = []
            for each season in show.seasons
                for each e in season.episodes
                    ids.Push(e.id)
                end for
            end for
            title = show.name
            choices.Push({ label: "Mark whole show as watched", action: "watched", ids: ids, watched: true })
            choices.Push({ label: "Mark whole show as not watched", action: "watched", ids: ids, watched: false })
        else if item <> invalid
            v = m.videos[item.videoId]
            if v <> invalid
                title = episodeLabel(v)
                choices.Append(videoChoices(v))
            end if
        end if
    end if
    choices.Push({ label: "Refresh library", action: "refresh" })
    showMenu(title, choices)
end sub

sub onShowMenu()
    req = m.showScreen.menuRequest
    if req.kind = "season"
        showMenu(m.showScreen.show.name + "  -  " + req.label, [
            { label: "Mark season as watched", action: "watched", ids: req.ids, watched: true },
            { label: "Mark season as not watched", action: "watched", ids: req.ids, watched: false }
        ])
    else
        v = m.videos[req.id]
        if v <> invalid then showMenu(episodeLabel(v), videoChoices(v))
    end if
end sub

sub openPlayerMenu()
    v = m.current
    if v = invalid then return
    choices = []
    if v.next_id <> invalid and m.videos.DoesExist(v.next_id)
        choices.Push({ label: "Next episode: " + episodeLabel(m.videos[v.next_id]), action: "next", id: v.next_id })
    end if
    if v.prev_id <> invalid and m.videos.DoesExist(v.prev_id)
        choices.Push({ label: "Previous episode: " + episodeLabel(m.videos[v.prev_id]), action: "previous", id: v.prev_id })
    end if
    choices.Push({ label: "Play from beginning", action: "startover" })
    m.video.control = "pause"
    showMenu(episodeLabel(v), choices)
end sub

' --- remote -----------------------------------------------------------------------

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.video.visible
        if key = "back"
            if m.upNext.visible
                dismissUpNext()
            else
                closeVideo()
            end if
            return true
        end if
        if key = "options"
            openPlayerMenu()
            return true
        end if
        ' The keys below reach this scene only while the Skip intro or Up Next
        ' button has focus. Keep playback controls working anyway.
        if key = "play"
            if m.video.state = "playing"
                m.video.control = "pause"
            else
                m.video.control = "resume"
            end if
            return true
        end if
        if key = "fwd" or key = "rev" or key = "left" or key = "right" or key = "up" or key = "down"
            if m.skip.visible
                m.skipDismissed = true
                hideSkip()
            end if
            m.video.setFocus(true)
            return true
        end if
        return false
    end if
    if key = "options" and not m.showScreen.visible
        openHomeMenu()
        return true
    end if
    return false
end function
