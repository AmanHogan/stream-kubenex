' Icon size and spacing in the paused screen.
function iconPitch() as Integer
    return 112
end function

sub init()
    m.bottom = m.top.findNode("bottom")
    m.details = m.top.findNode("details")
    m.icons = m.top.findNode("icons")
    m.tip = m.top.findNode("tip")
    m.track = m.top.findNode("track")
    m.fill = m.top.findNode("fill")
    m.knob = m.top.findNode("knob")
    m.elapsed = m.top.findNode("elapsed")
    m.remaining = m.top.findNode("remaining")
    m.center = m.top.findNode("center")
    m.centerGlyph = m.top.findNode("centerGlyph")
    m.centerText = m.top.findNode("centerText")
    m.centerFade = m.top.findNode("centerFade")
    m.hideTimer = m.top.findNode("hideTimer")
    m.hideTimer.observeField("fire", "onHideTimer")
    m.centerFade.observeField("state", "onCenterFadeState")
    m.actions = []
    m.centerKind = "none"
    m.strayTicks = 0
    reset()
end sub

sub onVideo()
    m.top.video.observeField("position", "onPosition")
end sub

' A new video (or the player closed): nothing shown, no seek, focus on the bar.
function reset(params = invalid as Dynamic) as Boolean
    m.mode = "hidden"       ' hidden | bar (playing, after Up/Down) | paused
    m.area = "bar"          ' bar | icons (paused only)
    m.iconIndex = 0
    m.target = -1           ' where a seek will go, in seconds; -1 = no seek
    m.resumeAfterSeek = false
    m.hideTimer.control = "stop"
    m.bottom.visible = false
    setCenter("none")
    return true
end function

sub onInfo()
    info = m.top.info
    logo = m.top.findNode("logo")
    logo.text = info.title
    logo.uri = info.logo
    m.top.findNode("episode").text = info.episode

    m.actions = [{ action: "startover", label: "Play from beginning", icon: "restart" }]
    if info.hasPrevious = true then m.actions.Push({ action: "previous", label: "Previous episode", icon: "previous" })
    if info.hasNext = true then m.actions.Push({ action: "next", label: "Next episode", icon: "next" })
    if info.hasSubtitles = true then m.actions.Push({ action: "subtitles", label: "Subtitles", icon: "subtitles" })
    m.icons.removeChildrenIndex(m.icons.getChildCount(), 0)
    for i = 0 to m.actions.Count() - 1
        g = m.icons.createChild("Group")
        g.translation = [i * iconPitch(), 0]
        ring = g.createChild("Poster")
        ring.uri = "pkg:/images/circle.png"
        ring.width = 84
        ring.height = 84
        glyph = g.createChild("Poster")
        glyph.uri = "pkg:/images/icon_" + m.actions[i].icon + ".png"
        glyph.width = 52
        glyph.height = 52
        glyph.translation = [16, 16]
    end for
    m.iconIndex = 0
    showIcons()
end sub

' The highlighted icon: white circle, black glyph, its name under it.
sub showIcons()
    onIcons = m.mode = "paused" and m.area = "icons"
    for i = 0 to m.icons.getChildCount() - 1
        g = m.icons.getChild(i)
        lit = onIcons and i = m.iconIndex
        g.getChild(0).visible = lit
        if lit
            g.getChild(1).blendColor = "0x000000FF"
        else
            g.getChild(1).blendColor = "0xFFFFFFFF"
        end if
    end for
    m.tip.visible = onIcons
    if onIcons
        m.tip.text = m.actions[m.iconIndex].label
        m.tip.translation = [96 + m.iconIndex * iconPitch() + 42 - 150, 836]
    end if
    m.knob.visible = m.mode <> "hidden" and m.area = "bar"
end sub

function duration() as Float
    d = 0
    if m.top.info <> invalid and m.top.info.duration <> invalid then d = m.top.info.duration
    if d <= 0 and m.top.video <> invalid then d = m.top.video.duration
    return d
end function

function currentPosition() as Float
    if m.target >= 0 then return m.target
    return m.top.video.position
end function

' A seek is waiting when the target is at least a second away from where the video is.
function seekPending() as Boolean
    return m.target >= 0 and Abs(m.target - m.top.video.position) >= 1
end function

sub onPosition()
    ' Safety net. The position only moves while playing; a pause, fast-forward or
    ' rewind icon must not stay then. Wait for 3 updates (about 1.5 s) in a row, since
    ' a pause just asked for may still report "playing" once.
    stray = m.centerKind = "pause" or m.centerKind = "ff" or m.centerKind = "rew"
    if stray and m.top.video.state = "playing"
        m.strayTicks = m.strayTicks + 1
        if m.strayTicks >= 3 then onPlaying()
    else
        m.strayTicks = 0
    end if
    if m.mode <> "hidden" then update()
end sub

sub update()
    d = duration()
    p = currentPosition()
    w = 0
    if d > 0 then w = Int(m.track.width * p / d)
    if w > m.track.width then w = m.track.width
    m.fill.width = w
    m.knob.translation = [w - 14, -11]
    m.elapsed.text = clock(p)
    if d > 0 then m.remaining.text = "-" + clock(d - p)
end sub

function clock(seconds as Float) as String
    s = Int(seconds)
    if s < 0 then s = 0
    h = Int(s / 3600)
    mins = Int((s MOD 3600) / 60)
    secs = s MOD 60
    out = ""
    if h > 0
        out = h.ToStr() + ":"
        if mins < 10 then out = out + "0"
    end if
    out = out + mins.ToStr() + ":"
    if secs < 10 then out = out + "0"
    return out + secs.ToStr()
end function

' --- the centre icon -------------------------------------------------------------------
' kind: none | pause | ff | rew | play. "play" fades out by itself.

sub setCenter(kind as String)
    m.centerFade.control = "stop"
    m.centerKind = kind
    m.strayTicks = 0
    if kind = "none"
        m.center.visible = false
        return
    end if
    m.centerGlyph.uri = "pkg:/images/icon_" + kind + ".png"
    m.centerText.text = ""
    m.center.opacity = 1.0
    m.center.visible = true
    if kind = "play" then m.centerFade.control = "start"
end sub

sub onCenterFadeState()
    if m.centerFade.state = "stopped" and m.centerKind = "play" then setCenter("none")
end sub

' While paused: fast-forward or rewind with the jump ("+1:30"), or pause.
sub refreshCenter()
    if m.mode <> "paused" then return
    if seekPending()
        delta = m.target - m.top.video.position
        if delta > 0
            if m.centerKind <> "ff" then setCenter("ff")
            m.centerText.text = "+" + clock(delta)
        else
            if m.centerKind <> "rew" then setCenter("rew")
            m.centerText.text = "-" + clock(-delta)
        end if
    else if m.centerKind <> "pause"
        setCenter("pause")
    end if
end sub

' --- showing and hiding ---------------------------------------------------------------

' The paused screen. MainScene calls this when the video pauses; a seek started
' from playing calls it at once, without waiting for the player.
function showPaused(params = invalid as Dynamic) as Boolean
    ' A seek sent with OK/Play may leave the player paused; carry on playing.
    if m.resumeAfterSeek
        m.resumeAfterSeek = false
        m.top.video.control = "resume"
        return true
    end if
    if m.mode <> "paused"
        m.mode = "paused"
        m.area = "bar"
    end if
    m.hideTimer.control = "stop"
    m.bottom.visible = true
    m.details.visible = true
    update()
    showIcons()
    refreshCenter()
    return true
end function

' Back to playing, whatever caused it: hide the paused screen, drop any seek, and
' turn a centre icon into the play icon that fades out.
function onPlaying(params = invalid as Dynamic) as Boolean
    m.resumeAfterSeek = false
    m.target = -1
    if m.mode = "paused"
        m.mode = "hidden"
        m.bottom.visible = false
    end if
    if m.centerKind = "pause" or m.centerKind = "ff" or m.centerKind = "rew" then setCenter("play")
    return true
end function

' Playing: just the bar, for a few seconds.
sub showBar()
    if m.mode = "paused" then return
    if m.mode <> "bar"
        m.mode = "bar"
        m.bottom.visible = true
        m.details.visible = false
        showIcons()
    end if
    update()
    m.hideTimer.control = "stop"
    m.hideTimer.control = "start"
end sub

sub onHideTimer()
    if m.mode = "bar"
        m.mode = "hidden"
        m.bottom.visible = false
    end if
end sub

' --- seeking ------------------------------------------------------------------------
' A seek only moves the target. OK or Play sends it to the player.

sub scrub(delta as Integer)
    v = m.top.video
    if m.mode <> "paused"
        ' Start from where it is playing now, and pause there.
        m.target = v.position
        v.control = "pause"
        showPaused()
    else if m.target < 0
        m.target = v.position
    end if
    d = duration()
    t = m.target + delta
    if t < 0 then t = 0
    if d > 0 and t > d - 5 then t = d - 5
    m.target = t
    if m.area <> "bar"
        m.area = "bar"
        showIcons()
    end if
    update()
    refreshCenter()
end sub

sub togglePlay()
    v = m.top.video
    if m.mode = "paused" or v.state = "paused"
        if seekPending()
            jumpAndPlay(m.target)
        else
            v.control = "resume"
        end if
    else
        v.control = "pause"
    end if
end sub

' Jump, then play. The player may stay paused after a seek; showPaused() then
' resumes it instead of showing the paused screen.
sub jumpAndPlay(seconds as Float)
    m.resumeAfterSeek = true
    m.top.video.seek = seconds
    m.top.video.control = "resume"
end sub

' MainScene: Play from beginning (from the icon or the * menu).
function playFrom(params as Dynamic) as Boolean
    jumpAndPlay(params.position)
    return true
end function

' --- remote -------------------------------------------------------------------------

function handleKey(key as Dynamic) as Boolean
    paused = m.mode = "paused"
    onIcons = paused and m.area = "icons"
    if key = "OK"
        if onIcons
            m.top.action = { action: m.actions[m.iconIndex].action }
        else
            togglePlay()
        end if
        return true
    else if key = "play"
        togglePlay()
        return true
    else if key = "left" or key = "right"
        if onIcons
            if key = "left" and m.iconIndex > 0 then m.iconIndex = m.iconIndex - 1
            if key = "right" and m.iconIndex < m.actions.Count() - 1 then m.iconIndex = m.iconIndex + 1
            showIcons()
        else if key = "left"
            scrub(-10)
        else
            scrub(10)
        end if
        return true
    else if key = "fwd"
        scrub(30)
        return true
    else if key = "rev"
        scrub(-30)
        return true
    else if key = "replay"
        scrub(-10)
        return true
    else if key = "up"
        if paused and m.actions.Count() > 0
            m.area = "icons"
            showIcons()
        else if not paused
            showBar()
        end if
        return true
    else if key = "down"
        if onIcons
            m.area = "bar"
            showIcons()
        else if not paused
            showBar()
        end if
        return true
    else if key = "back" and paused and seekPending()
        ' Cancel the seek; stay paused where the video is. Back again leaves.
        m.target = -1
        update()
        refreshCenter()
        return true
    end if
    return false
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    return handleKey(key)
end function
