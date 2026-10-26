sub init()
    m.grid = m.top.findNode("grid")
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.grid.observeField("itemSelected", "onItemSelected")
    m.video.observeField("state", "onVideoState")
    m.top.setFocus(true)
    loadFeed()
end sub

sub loadFeed()
    m.status.text = "Loading..."
    ' Network calls must run in a Task node, never on the render thread.
    m.feedTask = CreateObject("roSGNode", "FeedTask")
    m.feedTask.observeField("content", "onFeedLoaded")
    m.feedTask.observeField("error", "onFeedError")
    m.feedTask.control = "run"
end sub

sub onFeedLoaded()
    m.grid.content = m.feedTask.content
    count = m.feedTask.content.getChildCount()
    if count = 0
        m.status.text = "No videos yet. Add one from the web form, then press * to refresh."
    else
        m.status.text = count.toStr() + " videos  -  OK to play  -  * to refresh"
        m.grid.setFocus(true)
    end if
end sub

sub onFeedError()
    m.status.text = "Cannot load feed: " + m.feedTask.error + "  -  press * to retry"
end sub

sub onItemSelected()
    item = m.grid.content.getChild(m.grid.itemSelected)
    content = CreateObject("roSGNode", "ContentNode")
    content.url = item.url
    content.title = item.title
    content.streamFormat = "mp4"
    m.video.content = content
    m.video.visible = true
    m.video.setFocus(true)
    m.video.control = "play"
end sub

sub onVideoState()
    state = m.video.state
    if state = "error"
        m.status.text = "Playback error: " + m.video.errorMsg
        closeVideo()
    else if state = "finished"
        closeVideo()
    end if
end sub

sub closeVideo()
    m.video.control = "stop"
    m.video.visible = false
    if m.grid.content <> invalid and m.grid.content.getChildCount() > 0
        m.grid.setFocus(true)
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
    if key = "options" and not m.video.visible
        loadFeed()
        return true
    end if
    return false
end function
