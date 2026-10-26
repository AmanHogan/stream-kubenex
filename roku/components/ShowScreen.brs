sub init()
    m.seasons = m.top.findNode("seasons")
    m.episodes = m.top.findNode("episodes")
    m.seasons.observeField("itemFocused", "onSeasonFocused")
    m.seasons.observeField("itemSelected", "onSeasonSelected")
    m.episodes.observeField("itemSelected", "onEpisodeSelected")
end sub

sub onShow()
    show = m.top.show
    m.top.findNode("name").text = show.name

    list = CreateObject("roSGNode", "ContentNode")
    for each s in show.seasons
        item = list.createChild("ContentNode")
        if s.season = invalid
            item.title = "Other"
        else
            item.title = "Season " + s.season.ToStr()
        end if
    end for
    m.seasons.content = list
    m.seasons.jumpToItem = 0
    showSeason(0)

    m.top.visible = true
    m.episodes.setFocus(true)
end sub

sub onSeasonFocused()
    showSeason(m.seasons.itemFocused)
end sub

' OK on a season moves to its episodes.
sub onSeasonSelected()
    m.episodes.setFocus(true)
end sub

sub showSeason(index as Integer)
    seasons = m.top.show.seasons
    if index < 0 or index >= seasons.Count() then return
    grid = CreateObject("roSGNode", "ContentNode")
    for each e in seasons[index].episodes
        item = grid.createChild("ContentNode")
        fillVideoItem(item, e)
        ' The grid shows two caption lines: "E5  Title" and the length.
        label = item.title
        if e.episode <> invalid then label = "E" + e.episode.ToStr() + "  " + label
        item.SHORTDESCRIPTIONLINE1 = label
        item.SHORTDESCRIPTIONLINE2 = formatDuration(e.duration)
    end for
    m.episodes.content = grid
end sub

sub onEpisodeSelected()
    item = m.episodes.content.getChild(m.episodes.itemSelected)
    m.top.playVideo = { id: item.videoId, url: item.url, title: item.title }
end sub

' MainScene calls this (callFunc) after the player closes, so focus lands back on the grid.
' callFunc always passes one argument; this one ignores it.
function focusEpisodes(params = invalid as Dynamic) as Boolean
    m.episodes.setFocus(true)
    return true
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "right" and m.seasons.hasFocus()
        m.episodes.setFocus(true)
        return true
    end if
    ' The grid only passes Left up when the focus is already in its first column.
    if key = "left" and m.episodes.hasFocus()
        m.seasons.setFocus(true)
        return true
    end if
    if key = "back"
        m.top.visible = false
        m.top.closed = true
        return true
    end if
    return false
end function
