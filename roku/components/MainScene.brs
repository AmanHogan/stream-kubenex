sub init()
    m.rows = m.top.findNode("rows")
    m.showScreen = m.top.findNode("showScreen")
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.rows.observeField("rowItemSelected", "onRowItemSelected")
    m.showScreen.observeField("playVideo", "onPlayFromShow")
    m.showScreen.observeField("closed", "onShowClosed")
    m.video.observeField("state", "onVideoState")
    m.video.observeField("position", "onVideoPosition")
    ' Resume positions live on this Roku only: video id -> seconds.
    m.resume = CreateObject("roRegistrySection", "resume")
    m.playing = invalid
    m.lastSaved = 0
    m.top.setFocus(true)
    loadLibrary()
end sub

sub loadLibrary()
    m.status.text = "Loading..."
    ' Network calls must run in a Task node, never on the render thread.
    m.task = CreateObject("roSGNode", "LibraryTask")
    m.task.observeField("rows", "onLibraryLoaded")
    m.task.observeField("error", "onLibraryError")
    m.task.control = "run"
end sub

sub onLibraryLoaded()
    m.library = m.task.library
    m.rows.content = m.task.rows
    if m.task.rows.getChildCount() = 0
        m.status.text = "No videos yet. Add one from the web form, then press * to refresh."
        return
    end if
    m.status.text = "OK opens or plays  -  * refreshes"
    if not m.showScreen.visible and not m.video.visible then m.rows.setFocus(true)
end sub

sub onLibraryError()
    m.status.text = "Cannot load library: " + m.task.error + "  -  press * to retry"
end sub

sub onRowItemSelected()
    sel = m.rows.rowItemSelected
    item = m.rows.content.getChild(sel[0]).getChild(sel[1])
    if item.itemType = "show"
        m.showScreen.show = m.library.shows[item.showIndex]
    else
        play({ id: item.videoId, url: item.url, title: item.title })
    end if
end sub

sub onPlayFromShow()
    play(m.showScreen.playVideo)
end sub

sub onShowClosed()
    m.rows.setFocus(true)
end sub

' Plays a video, starting where it was stopped last time on this Roku.
sub play(v as Object)
    content = CreateObject("roSGNode", "ContentNode")
    content.url = v.url
    content.title = v.title
    content.streamFormat = "mp4"
    saved = m.resume.Read(v.id)
    if saved <> "" then content.PlayStart = saved.ToInt()
    m.playing = v.id
    m.lastSaved = 0
    m.video.content = content
    m.video.visible = true
    m.video.setFocus(true)
    m.video.control = "play"
end sub

' Saves the position every 10 seconds of playback.
sub onVideoPosition()
    if m.playing = invalid then return
    seconds = Int(m.video.position)
    if Abs(seconds - m.lastSaved) >= 10 then savePosition(seconds)
end sub

sub savePosition(seconds as Integer)
    m.lastSaved = seconds
    ' Near the start or the end there is nothing worth resuming.
    if seconds < 30 or (m.video.duration > 0 and seconds > m.video.duration - 60)
        m.resume.Delete(m.playing)
    else
        m.resume.Write(m.playing, seconds.ToStr())
    end if
    m.resume.Flush()
end sub

sub onVideoState()
    state = m.video.state
    if state = "error"
        m.status.text = "Playback error: " + m.video.errorMsg
        closeVideo()
    else if state = "finished"
        if m.playing <> invalid
            m.resume.Delete(m.playing)
            m.resume.Flush()
        end if
        closeVideo()
    end if
end sub

sub closeVideo()
    if m.playing <> invalid and m.video.state <> "finished" then savePosition(Int(m.video.position))
    m.playing = invalid
    m.video.control = "stop"
    m.video.visible = false
    if m.showScreen.visible
        m.showScreen.callFunc("focusEpisodes", {})
    else if m.rows.content <> invalid and m.rows.content.getChildCount() > 0
        m.rows.setFocus(true)
    else
        m.top.setFocus(true)
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "back" and m.video.visible
        closeVideo()
        return true
    end if
    if key = "options" and not m.video.visible and not m.showScreen.visible
        loadLibrary()
        return true
    end if
    return false
end function
