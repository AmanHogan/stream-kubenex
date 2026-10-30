sub onContent()
    item = m.top.itemContent
    m.top.findNode("poster").uri = item.HDPOSTERURL
    m.top.findNode("title").text = item.title
    m.top.findNode("sub").text = item.SHORTDESCRIPTIONLINE2

    partWatched = not item.isWatched and item.progressPos > 0 and item.lengthSec > 0
    m.top.findNode("track").visible = partWatched
    bar = m.top.findNode("bar")
    bar.visible = partWatched
    if partWatched then bar.width = Int(480 * item.progressPos / item.lengthSec)
    m.top.findNode("badge").visible = item.isWatched
end sub
