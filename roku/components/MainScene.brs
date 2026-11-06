' Watch state lives on the server (/api/progress, /api/watched). This scene
' reports the position while a video plays and reloads the library afterwards,
' so the progress bars, Continue Watching and Watched badges stay current.

sub init()
    m.home = m.top.findNode("home")
    m.showScreen = m.top.findNode("showScreen")
    m.video = m.top.findNode("video")
    m.skip = m.top.findNode("skipIntro")
    m.skipButton = m.top.findNode("skipButton")
    m.upNext = m.top.findNode("upNext")
    m.upNextTitle = m.top.findNode("upNextTitle")
    m.upNextCount = m.top.findNode("upNextCount")
    m.upNextButton = m.top.findNode("upNextButton")
    m.countdown = m.top.findNode("countdown")
    m.dialog = m.top.findNode("dialog")
    m.controls = m.top.findNode("controls")
    m.controls.video = m.video
    m.details = m.top.findNode("details")
    m.detailsBack = m.top.findNode("detailsBack")
    m.detailsArt = m.top.findNode("detailsArt")
    m.preview = m.top.findNode("preview")
    m.previewVideo = m.top.findNode("previewVideo")
    m.previewProgress = m.top.findNode("previewProgress")
    m.previewTrack = m.top.findNode("previewTrack")
    m.previewBar = m.top.findNode("previewBar")
    m.previewMask = m.top.findNode("previewMask")
    m.previewTimer = m.top.findNode("previewTimer")
    ' enableUI="false" hides the player's own bars; older firmware may lack it.
    for each bar in [m.previewVideo.bufferingBar, m.previewVideo.retrievingBar, m.previewVideo.trickPlayBar]
        if bar <> invalid then bar.visible = false
    end for

    m.home.observeField("focusedItem", "onHomeFocus")
    m.home.observeField("selectedItem", "onHomeSelected")
    m.home.observeField("playItem", "onHomePlay")
    m.home.observeField("heroAction", "onHeroAction")
    m.details.observeField("action", "onDetailsAction")
    m.details.observeField("closed", "onDetailsClosed")
    m.previewTimer.observeField("fire", "startPreview")
    m.previewVideo.observeField("state", "onPreviewState")
    m.previewVideo.observeField("position", "updatePreviewBar")
    m.showScreen.observeField("selectedVideoId", "onShowVideoSelected")
    m.showScreen.observeField("menuRequest", "onShowMenu")
    m.showScreen.observeField("closed", "onShowClosed")
    m.video.observeField("state", "onVideoState")
    m.video.observeField("position", "onVideoPosition")
    m.skipButton.buttons = ["Skip intro"]
    m.skipButton.observeField("selected", "onSkipPressed")
    m.upNextButton.buttons = ["Play now"]
    m.upNextButton.observeField("selected", "playNext")
    m.countdown.observeField("fire", "onCountdown")
    m.dialog.observeField("selected", "onDialogSelected")
    m.dialog.observeField("cancelled", "onDialogCancelled")
    m.controls.observeField("action", "onControlsAction")

    m.api = CreateObject("roSGNode", "ApiTask")
    m.api.observeField("completed", "onApiCompleted")
    m.api.control = "run"
    m.inFlight = 0
    m.pendingReload = false

    m.library = invalid
    m.videos = {}
    m.current = invalid       ' the video playing now (an entry of m.videos)
    m.choices = []
    m.wasPlaying = false      ' was the video playing when a menu opened over it
    m.detailsVideo = invalid  ' the video on the details screen
    m.previewing = invalid    ' the video in the preview
    ' Subtitle choice, kept on this Roku: "off", or "<language>" / "<language>:sdh".
    m.prefs = CreateObject("roRegistrySection", "prefs")
    m.subsApplied = false
    ' Turning subtitles on changes the Roku's own caption setting; put it back on exit.
    m.savedCaptionMode = invalid
    m.top.setFocus(true)
    loadLibrary()
end sub

' --- library ------------------------------------------------------------------

sub loadLibrary()
    if m.library = invalid then m.home.status = "Loading..."
    ' Network calls must run in a Task node, never on the render thread.
    m.task = CreateObject("roSGNode", "LibraryTask")
    m.task.observeField("rows", "onLibraryLoaded")
    m.task.observeField("error", "onLibraryError")
    m.task.control = "run"
end sub

sub onLibraryLoaded()
    m.library = m.task.library
    m.videos = m.task.videos
    setHero(m.library.hero)
    m.home.content = m.task.rows
    if m.task.rows.getChildCount() = 0
        m.home.status = "No videos yet. Add one from the web form, then press * and Refresh."
    else
        m.home.status = "OK for details   " + Chr(183) + "   Play to play   " + Chr(183) + "   * for more"
    end if
    ' A refresh while a show or a details screen is open updates it in place.
    if m.showScreen.visible
        s = findShow(m.showScreen.show.name)
        if s <> invalid then m.showScreen.show = s
    end if
    if m.details.visible and m.detailsVideo <> invalid
        v = m.videos[m.detailsVideo.id]
        if v <> invalid then setDetails(v)
    end if
    if not m.showScreen.visible and not m.video.visible and not m.dialog.visible and not m.details.visible then focusHome()
end sub

' The hero: the last watched video (the server picks Continue Watching's first, else
' the newest video).
sub setHero(v as Dynamic)
    if v = invalid
        m.home.heroShow = {}
        m.home.hero = {}
        return
    end if
    cont = m.library["continue"]
    kicker = "NEW"
    if intOr(v.position, 0) > 0 and v.watched <> true
        kicker = "CONTINUE WATCHING"
    else if cont <> invalid and cont.Count() > 0 and cont[0].id = v.id
        kicker = "UP NEXT"
    end if
    show = invalid
    if v.kind = "episode" then show = findShow(v.show)
    if show = invalid then show = {}
    m.home.heroKicker = kicker
    m.home.heroShow = show
    m.home.hero = v
end sub

sub onHeroAction()
    a = m.home.heroAction
    v = m.library.hero
    if v = invalid then return
    if a.action = "play"
        play(v, a.start)
    else if a.action = "show"
        s = findShow(v.show)
        if s <> invalid
            m.home.callFunc("stopHero", {})
            m.showScreen.show = s
        end if
    end if
end sub

function findShow(name as Dynamic) as Dynamic
    if m.library = invalid or name = invalid then return invalid
    for each s in m.library.shows
        if s.name = name then return s
    end for
    return invalid
end function

sub onLibraryError()
    m.home.status = "Cannot load library: " + m.task.error + "  -  press * to retry"
end sub

' --- home screen ----------------------------------------------------------------

sub focusHome()
    m.home.setFocus(true)
    schedulePreview()
end sub

sub onHomeFocus()
    if m.home.isInFocusChain() then schedulePreview()
end sub

' OK on a card: a show opens its seasons; a video opens its details.
sub onHomeSelected()
    item = m.home.selectedItem
    if item = invalid then return
    if item.itemType = "show"
        stopPreview()
        m.showScreen.show = m.library.shows[item.showIndex]
    else
        openDetails(m.videos[item.videoId])
    end if
end sub

' Play on a card plays at once, from where it stopped.
sub onHomePlay()
    item = m.home.playItem
    if item = invalid then return
    if item.itemType = "show"
        stopPreview()
        m.showScreen.show = m.library.shows[item.showIndex]
    else
        playResume(m.videos[item.videoId])
    end if
end sub

sub playResume(v as Dynamic)
    if v = invalid then return
    start = 0
    if v.watched <> true then start = intOr(v.position, 0)
    play(v, start)
end sub

' --- details screen ---------------------------------------------------------------

sub openDetails(v as Dynamic)
    if v = invalid then return
    setDetails(v)
    m.detailsBack.visible = true
    m.details.visible = true
    m.details.callFunc("focusButtons", {})
    ' A preview of this video that already plays moves behind the details text.
    if m.previewing <> invalid and m.previewing.id = v.id
        placePreview()
    else
        schedulePreview()
    end if
end sub

sub setDetails(v as Object)
    m.detailsVideo = v
    show = invalid
    if v.kind = "episode" then show = findShow(v.show)
    if show = invalid then show = {}
    ' The show first: onVideo reads it.
    m.details.show = show
    m.details.video = v
    m.detailsArt.uri = v.art
end sub

sub closeDetails()
    m.details.visible = false
    m.detailsBack.visible = false
    m.detailsVideo = invalid
    if m.previewing <> invalid then placePreview()
end sub

sub onDetailsClosed()
    closeDetails()
    focusHome()
end sub

sub onDetailsAction()
    a = m.details.action
    v = m.detailsVideo
    if v = invalid then return
    if a.action = "play"
        play(v, a.start)
    else if a.action = "show"
        ' The details screen stays under the show screen; Back returns to it.
        s = findShow(v.show)
        if s <> invalid
            stopPreview()
            m.showScreen.show = s
        end if
    end if
end sub

' --- preview ------------------------------------------------------------------------
' After previewTimer (10 s) on a video card or a details screen, that video plays
' with sound: inside the card, or behind the details text. It starts where you
' stopped, never reports progress, and stops when the selection changes.

' The video to preview now, or invalid.
function previewCandidate() as Dynamic
    if m.video.visible or m.showScreen.visible or m.dialog.visible then return invalid
    if m.details.visible then return m.detailsVideo
    item = m.home.focusedItem
    if item = invalid or item.itemType <> "video" then return invalid
    return m.videos[item.videoId]
end function

sub schedulePreview()
    v = previewCandidate()
    ' Same video (a refresh, Back from its details): let it play on.
    if v <> invalid and m.previewing <> invalid and m.previewing.id = v.id then return
    stopPreview()
    if v <> invalid then m.previewTimer.control = "start"
end sub

sub startPreview()
    v = previewCandidate()
    if v = invalid then return
    content = CreateObject("roSGNode", "ContentNode")
    content.url = v.url
    content.streamFormat = "mp4"
    if v.watched <> true and intOr(v.position, 0) > 0 then content.PlayStart = intOr(v.position, 0)
    m.previewing = v
    placePreview()
    m.previewVideo.content = content
    m.previewVideo.control = "play"
end sub

' Inside the expanded card on the home screen; the big picture on the details screen.
sub placePreview()
    if m.details.visible
        rect = [640, 0, 1280, 720]
    else
        rect = m.home.cardRect
    end if
    ' The details screen has its own progress bar and soft edges instead of corners.
    m.previewProgress.visible = not m.details.visible
    m.previewMask.visible = not m.details.visible
    m.preview.translation = [rect[0], rect[1]]
    m.previewVideo.width = rect[2]
    m.previewVideo.height = rect[3]
    m.previewMask.width = rect[2]
    m.previewMask.height = rect[3]
    m.previewTrack.width = rect[2]
    m.previewProgress.translation = [0, rect[3] + 10]
    updatePreviewBar()
end sub

sub onPreviewState()
    state = m.previewVideo.state
    ' Show it only once frames come, so the card's picture covers the loading time.
    if state = "playing" and m.previewing <> invalid
        m.preview.visible = true
    else if state = "finished" or state = "error"
        stopPreview()
    end if
end sub

sub updatePreviewBar()
    v = m.previewing
    if v = invalid or intOr(v.duration, 0) <= 0
        m.previewBar.width = 0
        return
    end if
    m.previewBar.width = Int(m.previewTrack.width * m.previewVideo.position / v.duration)
end sub

sub stopPreview()
    m.previewTimer.control = "stop"
    if m.previewing = invalid then return
    m.previewing = invalid
    m.preview.visible = false
    m.previewVideo.control = "stop"
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

sub onShowVideoSelected()
    selectVideo(m.videos[m.showScreen.selectedVideoId])
end sub

sub onShowClosed()
    restoreFocus()
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
    ' Most Rokus decode one video at a time.
    stopPreview()
    m.home.callFunc("stopHero", {})
    if m.current <> invalid then saveProgress(Int(m.video.position))
    content = CreateObject("roSGNode", "ContentNode")
    content.url = v.url
    content.title = v.title
    content.streamFormat = "mp4"
    if start > 0 then content.PlayStart = start
    tracks = []
    if v.subtitles <> invalid
        for each t in v.subtitles
            tracks.Push({ Language: t.language, TrackName: t.url, Description: t.label })
        end for
    end if
    content.SubtitleTracks = tracks
    m.subsApplied = false
    m.current = v
    m.lastSaved = start
    m.skipDismissed = false
    m.upNextState = "none"    ' none | showing | dismissed
    hideOverlays()
    m.video.content = content
    m.video.visible = true
    setControlsInfo(v)
    m.controls.visible = true
    m.controls.setFocus(true)
    m.video.control = "play"
end sub

sub setControlsInfo(v as Object)
    m.controls.callFunc("reset", {})
    isEpisode = v.kind = "episode" and v.show <> invalid
    title = "Untitled"
    if v.title <> invalid then title = v.title
    name = title
    episode = ""
    if isEpisode
        name = v.show
        episode = (episodeCode(v) + "  " + title).Trim()
    else if v.year <> invalid
        episode = v.year.ToStr()
    end if
    m.controls.info = {
        logo: strOr(v.logo), title: name, episode: episode, duration: intOr(v.duration, 0),
        hasPrevious: v.prev_id <> invalid and m.videos.DoesExist(v.prev_id),
        hasNext: v.next_id <> invalid and m.videos.DoesExist(v.next_id),
        hasSubtitles: hasSubtitles(v)
    }
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
    if focused then m.controls.setFocus(true)
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
    m.controls.setFocus(true)
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

' --- pause screen icons ---------------------------------------------------------------

sub onControlsAction()
    a = m.controls.action.action
    v = m.current
    if v = invalid then return
    if a = "startover"
        m.video.seek = 0
        m.video.control = "resume"
    else if a = "previous" and v.prev_id <> invalid
        play(m.videos[v.prev_id], 0)
    else if a = "next" and v.next_id <> invalid
        play(m.videos[v.next_id], 0)
    else if a = "subtitles"
        openSubtitleMenu()
    end if
end sub

' --- subtitles ----------------------------------------------------------------------
' Tracks come from the server (v.subtitles) and are attached in play(). Forced
' tracks hold only the foreign-language lines, so they show even with subtitles off.

function hasSubtitles(v as Object) as Boolean
    return v.subtitles <> invalid and v.subtitles.Count() > 0
end function

' The track to show for the saved choice, or invalid for none.
function pickSubtitle(tracks as Object, pref as String) as Dynamic
    forced = invalid
    for each t in tracks
        if t.forced = true and forced = invalid then forced = t
    end for
    if pref = "off" or pref = "" then return forced
    parts = pref.Split(":")
    wantSdh = parts.Count() > 1 and parts[1] = "sdh"
    sameLanguage = invalid
    for each t in tracks
        if t.forced <> true and t.language = parts[0]
            if (t.sdh = true) = wantSdh then return t
            if sameLanguage = invalid then sameLanguage = t
        end if
    end for
    if sameLanguage <> invalid then return sameLanguage
    return forced
end function

sub applySubtitles()
    if m.current = invalid or not hasSubtitles(m.current) then return
    m.subsApplied = true
    showSubtitle(pickSubtitle(m.current.subtitles, m.prefs.Read("subtitles")))
end sub

sub showSubtitle(t as Dynamic)
    if m.savedCaptionMode = invalid then m.savedCaptionMode = m.video.globalCaptionMode
    if t = invalid
        m.video.globalCaptionMode = "Off"
        return
    end if
    ' The player may list a side-loaded track under a longer name than its URL.
    name = t.url
    available = m.video.availableSubtitleTracks
    if available <> invalid
        for each a in available
            if a.TrackName = t.url or Instr(1, a.TrackName, t.url) > 0 then name = a.TrackName
        end for
    end if
    m.video.subtitleTrack = name
    m.video.globalCaptionMode = "On"
end sub

sub openSubtitleMenu()
    v = m.current
    if v = invalid or not hasSubtitles(v) then return
    shown = pickSubtitle(v.subtitles, m.prefs.Read("subtitles"))
    mark = "Off"
    if shown <> invalid and shown.forced <> true then mark = shown.label
    choices = [{ label: "Off", action: "subtitle", pref: "off" }]
    for each t in v.subtitles
        if t.forced <> true
            pref = t.language
            if t.sdh = true then pref = pref + ":sdh"
            choices.Push({ label: t.label, action: "subtitle", pref: pref })
        end if
    end for
    for each c in choices
        if c.label = mark then c.label = c.label + "   (on)"
    end for
    m.wasPlaying = m.video.state = "playing"
    m.video.control = "pause"
    showMenu("Subtitles", choices)
end sub

sub restoreCaptionMode()
    if m.savedCaptionMode <> invalid
        m.video.globalCaptionMode = m.savedCaptionMode
        m.savedCaptionMode = invalid
    end if
end sub

sub onVideoState()
    state = m.video.state
    ' Subtitle tracks are known once the video plays; apply the saved choice then.
    if state = "playing" and not m.subsApplied then applySubtitles()
    ' A seek sent while paused can start playback; pause again on the new frame.
    if state = "playing" and m.controls.holdPause
        m.controls.holdPause = false
        m.video.control = "pause"
        return
    end if
    if state = "paused"
        ' A menu pauses the video too; it has its own choices.
        if not m.dialog.visible and not m.upNext.visible then m.controls.callFunc("showPaused", {})
        if m.upNext.visible then m.countdown.control = "stop"
    else if state = "playing"
        m.controls.callFunc("onPlaying", {})
        if m.upNext.visible then m.countdown.control = "start"
    end if
    if state = "error"
        m.home.status = "Playback error: " + m.video.errorMsg
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
    m.controls.callFunc("reset", {})
    m.controls.visible = false
    restoreCaptionMode()
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
    restoreFocus()
    ' Back to how it was: playing, or the pause screen.
    if m.video.visible and m.video.state = "paused"
        if m.wasPlaying
            m.video.control = "resume"
        else
            m.controls.callFunc("showPaused", {})
        end if
    end if
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
        m.controls.setFocus(true)
    else if c.action = "refresh"
        loadLibrary()
        restoreFocus()
    else if c.action = "subtitle"
        m.prefs.Write("subtitles", c.pref)
        m.prefs.Flush()
        applySubtitles()
        m.video.control = "resume"
        m.controls.setFocus(true)
    else if c.action = "subtitlemenu"
        openSubtitleMenu()
    end if
end sub

sub restoreFocus()
    if m.video.visible
        m.controls.setFocus(true)
    else if m.showScreen.visible
        m.showScreen.callFunc("restoreFocus", {})
    else if m.details.visible
        m.details.callFunc("focusButtons", {})
        schedulePreview()
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
    item = m.home.focusedItem
    if m.home.heroFocused and m.library <> invalid and m.library.hero <> invalid
        title = episodeLabel(m.library.hero)
        choices.Append(videoChoices(m.library.hero))
    else if item <> invalid
        if item.itemType = "show"
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
        else
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
    if hasSubtitles(v) then choices.Push({ label: "Subtitles", action: "subtitlemenu" })
    m.wasPlaying = m.video.state = "playing"
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
        ' Other keys reach this scene from the Skip intro or Up Next button (they
        ' use only OK). Pass them to the controls, which seek and pause.
        if m.skip.visible
            m.skipDismissed = true
            hideSkip()
        end if
        m.controls.setFocus(true)
        return m.controls.callFunc("handleKey", key)
    end if
    if m.showScreen.visible then return false
    if key = "options"
        if m.details.visible and m.detailsVideo <> invalid
            showMenu(episodeLabel(m.detailsVideo), videoChoices(m.detailsVideo))
        else
            openHomeMenu()
        end if
        return true
    end if
    if key = "play" and m.details.visible
        playResume(m.detailsVideo)
        return true
    end if
    return false
end function
