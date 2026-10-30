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
    m.hero = m.top.findNode("hero")
    m.heroButtons = m.top.findNode("heroButtons")
    m.pauseBar = m.top.findNode("pauseBar")
    m.pauseButtons = m.top.findNode("pauseButtons")

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
    m.heroButtons.observeField("buttonSelected", "onHeroButton")
    m.pauseButtons.observeField("buttonSelected", "onPauseButton")

    m.api = CreateObject("roSGNode", "ApiTask")
    m.api.observeField("completed", "onApiCompleted")
    m.api.control = "run"
    m.inFlight = 0
    m.pendingReload = false

    m.library = invalid
    m.videos = {}
    m.current = invalid     ' the video playing now (an entry of m.videos)
    m.choices = []
    m.heroVideo = invalid   ' the video in the home banner
    m.heroActions = []
    m.pauseActions = []
    m.homeFocus = "hero"    ' hero | rows: where focus goes back to on the home screen
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
    setHero(m.library.hero)
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
    if not m.showScreen.visible and not m.video.visible and not m.dialog.visible then focusHome()
end sub

' --- home banner ----------------------------------------------------------------

sub setHero(v as Dynamic)
    m.heroVideo = v
    if v = invalid
        m.hero.visible = false
        m.homeFocus = "rows"
        m.rows.translation = [96, 170]
        return
    end if
    m.top.findNode("heroArt").uri = v.art
    position = intOr(v.position, 0)
    ' The server takes the hero from Continue Watching when there is anything in it.
    cont = m.library["continue"]
    fromContinue = cont <> invalid and cont.Count() > 0 and cont[0].id = v.id
    if position > 0
        m.top.findNode("heroKicker").text = "CONTINUE WATCHING"
    else if fromContinue
        m.top.findNode("heroKicker").text = "UP NEXT"
    else
        m.top.findNode("heroKicker").text = "RECENTLY ADDED"
    end if
    if v.kind = "episode" and v.show <> invalid
        m.top.findNode("heroTitle").text = v.show
        m.top.findNode("heroSub").text = episodeLabel(v) + "  -  " + watchState(v)
    else
        m.top.findNode("heroTitle").text = v.title
        m.top.findNode("heroSub").text = watchState(v)
    end if

    m.heroActions = []
    if position > 0
        m.heroActions.Push({ label: "Resume", action: "play", start: position })
        m.heroActions.Push({ label: "Play from beginning", action: "play", start: 0 })
    else
        m.heroActions.Push({ label: "Play", action: "play", start: 0 })
    end if
    if v.kind = "episode" and v.show <> invalid then m.heroActions.Push({ label: "Go to show", action: "show" })
    labels = []
    for each a in m.heroActions
        labels.Push(a.label)
    end for
    m.heroButtons.buttons = labels
    if m.homeFocus = "hero" then showHeroLayout()
end sub

' The banner on top, one row of cards under it.
sub showHeroLayout()
    m.hero.visible = true
    m.rows.translation = [96, 660]
end sub

' No banner: the rows take the whole screen.
sub showRowsLayout()
    m.hero.visible = false
    m.rows.translation = [96, 170]
end sub

sub focusHome()
    if m.homeFocus = "hero" and m.heroVideo <> invalid
        showHeroLayout()
        m.heroButtons.setFocus(true)
    else if m.rows.content <> invalid and m.rows.content.getChildCount() > 0
        m.homeFocus = "rows"
        showRowsLayout()
        m.rows.setFocus(true)
    else
        m.top.setFocus(true)
    end if
end sub

sub onHeroButton()
    a = m.heroActions[m.heroButtons.buttonSelected]
    v = m.heroVideo
    if a.action = "play"
        play(v, a.start)
    else if a.action = "show"
        for each s in m.library.shows
            if s.name = v.show then m.showScreen.show = s
        end for
    end if
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
    focusHome()
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
    m.upNextCount.text = "Starts in " + m.countdownLeft.ToStr() + " s  -  Back to keep watching"
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
    m.pauseBar.visible = false
end sub

' --- pause controls ---------------------------------------------------------------

sub showPauseBar()
    v = m.current
    if v = invalid then return
    m.pauseActions = [{ label: "Resume", action: "resume" }]
    if v.prev_id <> invalid and m.videos.DoesExist(v.prev_id)
        m.pauseActions.Push({ label: "Previous episode", action: "episode", id: v.prev_id })
    end if
    m.pauseActions.Push({ label: "Play from beginning", action: "startover" })
    if v.next_id <> invalid and m.videos.DoesExist(v.next_id)
        m.pauseActions.Push({ label: "Next episode", action: "episode", id: v.next_id })
    end if
    labels = []
    for each a in m.pauseActions
        labels.Push(a.label)
    end for
    m.pauseButtons.buttons = labels
    m.pauseBar.visible = true
    ' Resume first, so OK on a paused video still resumes it.
    m.pauseButtons.focusButton = 0
    m.pauseButtons.setFocus(true)
end sub

sub hidePauseBar()
    inFocus = m.pauseButtons.isInFocusChain()
    m.pauseBar.visible = false
    if inFocus then m.video.setFocus(true)
end sub

sub onPauseButton()
    a = m.pauseActions[m.pauseButtons.buttonSelected]
    hidePauseBar()
    if a.action = "resume"
        m.video.control = "resume"
    else if a.action = "startover"
        m.video.seek = 0
        m.video.control = "resume"
    else if a.action = "episode"
        play(m.videos[a.id], 0)
    end if
end sub

sub onVideoState()
    state = m.video.state
    if state = "paused"
        ' The menu pauses the video too; it has its own choices.
        if not m.dialog.visible and not m.upNext.visible then showPauseBar()
        if m.upNext.visible then m.countdown.control = "stop"
    else if state = "playing"
        if m.pauseBar.visible then hidePauseBar()
        if m.upNext.visible then m.countdown.control = "start"
    end if
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
    else
        focusHome()
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
        choices.Push({ label: "Next: " + episodeLabel(m.videos[v.next_id]), action: "next", id: v.next_id })
    end if
    if v.prev_id <> invalid and m.videos.DoesExist(v.prev_id)
        choices.Push({ label: "Previous: " + episodeLabel(m.videos[v.prev_id]), action: "previous", id: v.prev_id })
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
            if m.pauseBar.visible then hidePauseBar()
            m.video.setFocus(true)
            return true
        end if
        return false
    end if
    if m.showScreen.visible then return false
    ' Home: Down leaves the banner for the rows; Up on the first row goes back.
    if key = "down" and m.heroButtons.isInFocusChain() and m.rows.content <> invalid and m.rows.content.getChildCount() > 0
        m.homeFocus = "rows"
        focusHome()
        return true
    end if
    if key = "up" and m.rows.hasFocus() and m.heroVideo <> invalid
        m.homeFocus = "hero"
        focusHome()
        return true
    end if
    if key = "options"
        if m.heroButtons.isInFocusChain() and m.heroVideo <> invalid
            showMenu(episodeLabel(m.heroVideo), videoChoices(m.heroVideo))
        else
            openHomeMenu()
        end if
        return true
    end if
    return false
end function
