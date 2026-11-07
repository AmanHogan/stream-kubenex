sub init()
    m.seasons = m.top.findNode("seasons")
    m.episodes = m.top.findNode("episodes")
    m.seasons.observeField("itemFocused", "onSeasonFocused")
    m.seasons.observeField("itemSelected", "onSeasonSelected")
    m.episodes.observeField("itemSelected", "onEpisodeSelected")
    m.showName = invalid
    m.seasonIndex = 0
    m.lastFocus = "episodes"
end sub

sub onShow()
    show = m.top.show
    ' Same show again = a refresh after playback: keep the place.
    sameShow = m.showName <> invalid and m.showName = show.name
    keepEpisode = 0
    if sameShow then keepEpisode = m.episodes.itemFocused
    if not sameShow then m.seasonIndex = 0
    m.showName = show.name
    logo = m.top.findNode("logo")
    logo.text = show.name
    logo.uri = strOr(show.logo)
    m.top.findNode("backdrop").uri = show.art
    parts = []
    if show.year <> invalid then parts.Push(show.year.ToStr())
    count = intOr(show.season_count, 0)
    if count = 1 then parts.Push("1 Season")
    if count > 1 then parts.Push(count.ToStr() + " Seasons")
    m.top.findNode("meta").text = parts.Join("   " + Chr(183) + "   ")

    ' "Season 1  (10 episodes)"
    list = CreateObject("roSGNode", "ContentNode")
    for each s in show.seasons
        item = list.createChild("ContentNode")
        if s.season = invalid
            item.title = "Other"
        else
            item.title = "Season " + s.season.ToStr()
        end if
        n = s.episodes.Count()
        if n = 1
            item.title = item.title + "  (1 episode)"
        else
            item.title = item.title + "  (" + n.ToStr() + " episodes)"
        end if
    end for
    if m.seasonIndex >= show.seasons.Count() then m.seasonIndex = 0
    m.seasons.content = list
    m.seasons.jumpToItem = m.seasonIndex
    showSeason(m.seasonIndex)
    if keepEpisode > 0 and keepEpisode < m.episodes.content.getChildCount() then m.episodes.jumpToItem = keepEpisode

    if not sameShow
        m.top.visible = true
        m.lastFocus = "episodes"
        m.episodes.setFocus(true)
    end if
end sub

sub onSeasonFocused()
    if m.seasons.itemFocused = m.seasonIndex and m.episodes.content <> invalid then return
    m.seasonIndex = m.seasons.itemFocused
    showSeason(m.seasonIndex)
end sub

' OK on a season moves to its episodes.
sub onSeasonSelected()
    focusEpisodes()
end sub

sub showSeason(index as Integer)
    seasons = m.top.show.seasons
    if index < 0 or index >= seasons.Count() then return
    grid = CreateObject("roSGNode", "ContentNode")
    for each e in seasons[index].episodes
        item = grid.createChild("ContentNode")
        fillVideoItem(item, e)
        ' "5.  Title", then "45 min" or "12 min left" or "Watched", then the synopsis.
        label = item.title
        if e.episode <> invalid then label = e.episode.ToStr() + ".  " + label
        parts = []
        if e.duration <> invalid and e.duration > 0 then parts.Push(Int((e.duration + 59) / 60).ToStr() + " min")
        if e.watched = true or intOr(e.position, 0) > 0 then parts.Push(watchState(e))
        meta = parts.Join("   " + Chr(183) + "   ")
        item.addFields({ episodeTitle: label, episodeMeta: meta, episodeDesc: strOr(e.description) })
    end for
    m.episodes.content = grid
end sub

sub onEpisodeSelected()
    item = m.episodes.content.getChild(m.episodes.itemSelected)
    m.top.selectedVideoId = item.videoId
end sub

sub focusEpisodes()
    m.lastFocus = "episodes"
    m.episodes.setFocus(true)
end sub

sub focusSeasons()
    m.lastFocus = "seasons"
    m.seasons.setFocus(true)
end sub

' MainScene calls this (callFunc) after a video or a menu closes. callFunc always
' passes one argument; this one ignores it.
function restoreFocus(params = invalid as Dynamic) as Boolean
    if m.lastFocus = "seasons"
        m.seasons.setFocus(true)
    else
        m.episodes.setFocus(true)
    end if
    return true
end function

sub requestMenu()
    if m.seasons.hasFocus()
        season = m.top.show.seasons[m.seasonIndex]
        ids = []
        for each e in season.episodes
            ids.Push(e.id)
        end for
        m.top.menuRequest = { kind: "season", ids: ids, label: m.seasons.content.getChild(m.seasonIndex).title }
    else if m.episodes.content <> invalid and m.episodes.content.getChildCount() > 0
        item = m.episodes.content.getChild(m.episodes.itemFocused)
        m.top.menuRequest = { kind: "episode", id: item.videoId }
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "right" and m.seasons.hasFocus()
        focusEpisodes()
        return true
    end if
    ' The grid only passes Left up when the focus is already in its first column.
    if key = "left" and m.episodes.hasFocus()
        focusSeasons()
        return true
    end if
    if key = "options"
        requestMenu()
        return true
    end if
    ' The lists pass OK up after acting on it; it is used here, not by the player.
    if key = "OK" then return true
    if key = "back"
        m.top.visible = false
        m.showName = invalid
        m.top.closed = true
        return true
    end if
    return false
end function
