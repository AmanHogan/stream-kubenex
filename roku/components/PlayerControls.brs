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
    m.hideTimer = m.top.findNode("hideTimer")
    m.seekTimer = m.top.findNode("seekTimer")
    m.hideTimer.observeField("fire", "onHideTimer")
    m.seekTimer.observeField("fire", "commitSeek")
    m.actions = []
    m.sinceSeek = CreateObject("roTimespan")
    reset()
end sub

sub onVideo()
    m.top.video.observeField("position", "onPosition")
end sub

' A new video: nothing shown, no seek pending, focus on the bar.
function reset(params = invalid as Dynamic) as Boolean
    m.mode = "hidden"     ' hidden | bar (playing, after a seek) | paused
    m.area = "bar"        ' bar | icons (paused only)
    m.iconIndex = 0
    m.target = -1         ' seek target in seconds, until the player gets there
    m.seekPending = false ' presses still adding up; not sent to the player yet
    m.top.holdPause = false
    m.hideTimer.control = "stop"
    m.seekTimer.control = "stop"
    m.bottom.visible = false
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

sub onPosition()
    ' The player reports the old place for a moment after a seek; keep showing the target.
    if m.target >= 0 and not m.seekPending
        if Abs(m.top.video.position - m.target) < 2 or m.sinceSeek.TotalSeconds() > 6 then m.target = -1
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

' --- showing and hiding ---------------------------------------------------------------

function showPaused(params = invalid as Dynamic) as Boolean
    m.mode = "paused"
    m.area = "bar"
    m.hideTimer.control = "stop"
    m.bottom.visible = true
    m.details.visible = true
    update()
    showIcons()
    return true
end function

function onPlaying(params = invalid as Dynamic) as Boolean
    if m.mode = "paused"
        m.mode = "hidden"
        m.bottom.visible = false
    end if
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
' Presses add up; the player seeks once they stop for 0.35 s.

sub scrub(delta as Integer)
    d = duration()
    t = currentPosition() + delta
    if t < 0 then t = 0
    if d > 0 and t > d - 5 then t = d - 5
    m.target = t
    toBar = m.area <> "bar"
    m.area = "bar"
    if m.mode = "paused"
        update()
        if toBar then showIcons()
    else
        showBar()
    end if
    m.seekPending = true
    m.seekTimer.control = "stop"
    m.seekTimer.control = "start"
end sub

sub commitSeek()
    m.seekTimer.control = "stop"
    if not m.seekPending or m.target < 0 then return
    m.seekPending = false
    if m.top.video.state = "paused" then m.top.holdPause = true
    m.sinceSeek.Mark()
    m.top.video.seek = m.target
    ' Playing: keep the bar up a little after the jump.
    if m.mode = "bar"
        m.hideTimer.control = "stop"
        m.hideTimer.control = "start"
    end if
end sub

sub togglePlay()
    v = m.top.video
    if v.state = "paused"
        ' A seek still adding up goes now, then play resumes from there.
        if m.seekPending
            m.seekPending = false
            m.seekTimer.control = "stop"
            m.sinceSeek.Mark()
            v.seek = m.target
        end if
        m.top.holdPause = false
        v.control = "resume"
    else
        v.control = "pause"
    end if
end sub

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
    end if
    return false
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    return handleKey(key)
end function
