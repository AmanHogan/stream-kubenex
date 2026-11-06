' Card sizes; HomeRow uses the same numbers (see layout() there).
function boxWidth() as Integer
    return 320
end function

function wideWidth() as Integer
    return 854
end function

sub init()
    m.root = m.top.findNode("root")
    m.wide = m.top.findNode("wide")
    m.widePoster = m.top.findNode("widePoster")
    m.info = m.top.findNode("info")
    m.track = m.top.findNode("track")
    m.bar = m.top.findNode("bar")
    m.moveAnim = m.top.findNode("moveAnim")
    m.moveTo = m.top.findNode("moveTo")
    m.fadeAnim = m.top.findNode("fadeAnim")
    m.fadeWide = m.top.findNode("fadeWide")
    m.fadeInfo = m.top.findNode("fadeInfo")
    m.fadeAnim.observeField("state", "onFadeState")
    ' The badge background fits its text, so "Watched" is never cut off.
    w = Int(m.top.findNode("badgeText").boundingRect().width) + 28
    m.top.findNode("badgeBg").width = w
end sub

sub onContent()
    item = m.top.itemContent
    hasBox = item.boxUrl <> invalid and item.boxUrl <> ""
    m.top.findNode("boxPoster").uri = item.boxUrl
    fallback = m.top.findNode("fallback")
    fallback.visible = not hasBox
    if not hasBox
        m.top.findNode("fallbackPoster").uri = item.HDPOSTERURL
        m.top.findNode("fallbackName").text = item.cardName
    end if
    if m.top.expanded then m.widePoster.uri = item.HDPOSTERURL
    m.top.findNode("line1").text = item.line1
    m.top.findNode("line2").text = item.line2
    m.top.findNode("line3").text = item.line3
    m.top.findNode("badge").visible = item.isWatched
    showProgress()
end sub

' The red bar under the card while part-watched, as wide as the card is now.
sub showProgress()
    item = m.top.itemContent
    if item = invalid then return
    partWatched = not item.isWatched and item.progressPos > 0 and item.lengthSec > 0
    m.track.visible = partWatched
    m.bar.visible = partWatched
    w = boxWidth()
    if m.top.expanded then w = wideWidth()
    m.track.width = w
    if partWatched then m.bar.width = Int(w * item.progressPos / item.lengthSec)
end sub

sub onX()
    target = [m.top.x, 0]
    m.moveAnim.control = "stop"
    if m.top.animate
        m.moveTo.keyValue = [m.root.translation, target]
        m.moveAnim.control = "start"
    else
        m.root.translation = target
    end if
end sub

sub onExpanded()
    m.fadeAnim.control = "stop"
    target = 0.0
    if m.top.expanded
        target = 1.0
        ' One wide picture in memory at a time, not one per card.
        if m.top.itemContent <> invalid then m.widePoster.uri = m.top.itemContent.HDPOSTERURL
        if not m.wide.visible
            m.wide.opacity = 0
            m.info.opacity = 0
        end if
        m.wide.visible = true
        m.info.visible = true
    end if
    if m.top.animate and m.wide.visible
        ' Fade from wherever it is now, so a quick change of mind never jumps.
        m.fadeWide.keyValue = [m.wide.opacity, target]
        m.fadeInfo.keyValue = [m.info.opacity, target]
        m.fadeAnim.control = "start"
    else
        m.wide.opacity = target
        m.info.opacity = target
        onFadeState()
    end if
    showProgress()
end sub

' After fading out: hide the wide picture and free it.
sub onFadeState()
    if m.top.expanded or m.fadeAnim.state = "running" then return
    m.wide.visible = false
    m.info.visible = false
    m.widePoster.uri = ""
end sub
