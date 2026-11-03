' 960 / 512: the expanded picture is 960x540.
function bigScale() as Float
    return 1.875
end function

sub init()
    m.root = m.top.findNode("root")
    m.pic = m.top.findNode("pic")
    m.bigPoster = m.top.findNode("bigPoster")
    m.small = m.top.findNode("small")
    m.info = m.top.findNode("info")
    m.moveAnim = m.top.findNode("moveAnim")
    m.moveTo = m.top.findNode("moveTo")
    m.growAnim = m.top.findNode("growAnim")
    m.growTo = m.top.findNode("growTo")
end sub

sub onContent()
    item = m.top.itemContent
    m.top.findNode("poster").uri = item.HDPOSTERURL
    if m.top.expanded then m.bigPoster.uri = item.HDPOSTERURL
    m.small.text = item.smallLabel
    m.top.findNode("line1").text = item.line1
    m.top.findNode("line2").text = item.line2
    m.top.findNode("line3").text = item.line3

    partWatched = not item.isWatched and item.progressPos > 0 and item.lengthSec > 0
    m.top.findNode("track").visible = partWatched
    bar = m.top.findNode("bar")
    bar.visible = partWatched
    if partWatched then bar.width = Int(512 * item.progressPos / item.lengthSec)
    m.top.findNode("badge").visible = item.isWatched
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
    s = 1.0
    if m.top.expanded then s = bigScale()
    m.growAnim.control = "stop"
    if m.top.animate
        m.growTo.keyValue = [m.pic.scale, [s, s]]
        m.growAnim.control = "start"
    else
        m.pic.scale = [s, s]
    end if
    m.small.visible = not m.top.expanded
    m.info.visible = m.top.expanded
    ' Keep one full-size picture in memory at a time, not one per card.
    if m.top.expanded and m.top.itemContent <> invalid
        m.bigPoster.uri = m.top.itemContent.HDPOSTERURL
    else
        m.bigPoster.uri = ""
    end if
end sub
