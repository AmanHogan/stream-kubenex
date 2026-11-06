sub init()
    m.buttons = m.top.findNode("buttons")
    m.buttons.observeField("selected", "onButton")
    m.actions = []
end sub

sub onVideo()
    v = m.top.video
    show = m.top.show
    isEpisode = v.kind = "episode" and v.show <> invalid
    position = intOr(v.position, 0)
    name = "Untitled"
    if v.title <> invalid then name = v.title

    ' The logo when one was uploaded, else the name as text.
    logo = m.top.findNode("logo")
    if isEpisode
        logo.text = v.show
    else
        logo.text = name
    end if
    logo.uri = strOr(v.logo)

    ' "2011  ·  3 Seasons  ·  58 min" — each part only when known.
    parts = []
    year = v.year
    if isEpisode and show <> invalid then year = show.year
    if year <> invalid then parts.Push(year.ToStr())
    if isEpisode and show <> invalid and show.season_count <> invalid and show.season_count > 0
        if show.season_count = 1
            parts.Push("1 Season")
        else
            parts.Push(show.season_count.ToStr() + " Seasons")
        end if
    end if
    if v.kind = "clip" and v.uploader <> invalid and v.uploader <> "" then parts.Push(v.uploader)
    if v.duration <> invalid and v.duration > 0 then parts.Push(Int((v.duration + 59) / 60).ToStr() + " min")
    m.top.findNode("meta").text = parts.Join("   " + Chr(183) + "   ")

    episode = m.top.findNode("episode")
    if isEpisode
        episode.text = (episodeCode(v) + "  " + name).Trim()
    else
        episode.text = ""
    end if

    progress = m.top.findNode("progress")
    partWatched = position > 0 and v.watched <> true and intOr(v.duration, 0) > 0
    progress.visible = partWatched or v.watched = true
    if partWatched
        m.top.findNode("progressBar").width = Int(420 * position / v.duration)
    else if v.watched = true
        m.top.findNode("progressBar").width = 420
    end if
    m.top.findNode("left").text = watchState(v)

    ' The episode's own synopsis, else the show's.
    text = ""
    if v.description <> invalid then text = v.description
    if text = "" and isEpisode and show <> invalid and show.description <> invalid then text = show.description
    m.top.findNode("synopsis").text = text

    m.actions = []
    if position > 0 and v.watched <> true
        m.actions.Push({ label: "Resume", action: "play", start: position, icon: "play" })
        m.actions.Push({ label: "Play from beginning", action: "play", start: 0, icon: "restart" })
    else
        m.actions.Push({ label: "Play", action: "play", start: 0, icon: "play" })
    end if
    if isEpisode then m.actions.Push({ label: "Go to show", action: "show", icon: "episodes" })
    labels = []
    icons = []
    for each a in m.actions
        labels.Push(a.label)
        icons.Push("pkg:/images/icon_" + a.icon + ".png")
    end for
    m.buttons.icons = icons
    m.buttons.buttons = labels
    m.buttons.focusIndex = 0
    stackLines()
end sub

' Put each line under the one above it, skipping empty ones.
sub stackLines()
    y = 90 + 220 + 24
    for each id in ["meta", "episode", "progress", "synopsis"]
        node = m.top.findNode(id)
        shown = node.visible
        if id <> "progress" then shown = node.text <> ""
        if shown
            if id = "progress"
                node.translation = [96, y + 18]
                y = y + 56
            else
                node.translation = [96, y]
                y = y + Int(node.boundingRect().height) + 20
            end if
        end if
    end for
    m.buttons.translation = [96, y + 16]
end sub

sub onButton()
    a = m.actions[m.buttons.selected]
    m.top.action = { action: a.action, start: a.start }
end sub

function focusButtons(params = invalid as Dynamic) as Boolean
    m.buttons.setFocus(true)
    return true
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "back"
        m.top.closed = true
        return true
    end if
    ' Up and Down have nowhere to go here.
    return key = "up" or key = "down"
end function
