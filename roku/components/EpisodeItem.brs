sub onContent()
    item = m.top.itemContent
    m.top.findNode("thumb").uri = item.thumbUrl
    m.top.findNode("title").text = item.episodeTitle
    m.top.findNode("meta").text = item.episodeMeta
    m.top.findNode("desc").text = item.episodeDesc
    partWatched = not item.isWatched and item.progressPos > 0 and item.lengthSec > 0
    m.top.findNode("track").visible = partWatched or item.isWatched
    bar = m.top.findNode("bar")
    bar.visible = partWatched or item.isWatched
    if item.isWatched
        bar.width = 320
    else if partWatched
        bar.width = Int(320 * item.progressPos / item.lengthSec)
    end if
end sub
