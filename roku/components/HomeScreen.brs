' The active row's title is at y = top(); its expanded picture starts 56 px lower.
function top() as Integer
    return 120
end function

' While the hero has focus, the first row's title is here (the rows peek under it).
function heroRowsTop() as Integer
    return 900
end function

sub init()
    m.stack = m.top.findNode("stack")
    m.scrollAnim = m.top.findNode("scrollAnim")
    m.scrollTo = m.top.findNode("scrollTo")
    m.heroGroup = m.top.findNode("hero")
    m.heroButtons = m.top.findNode("heroButtons")
    m.heroVideo = m.top.findNode("heroVideo")
    m.heroTimer = m.top.findNode("heroTimer")
    m.heroButtons.observeField("selected", "onHeroButton")
    m.heroVideo.observeField("state", "onHeroVideoState")
    m.heroTimer.observeField("fire", "startHeroVideo")
    m.top.observeField("focusedChild", "onFocusChange")
    for each bar in [m.heroVideo.bufferingBar, m.heroVideo.retrievingBar, m.heroVideo.trickPlayBar]
        if bar <> invalid then bar.visible = false
    end for
    m.rowIndex = 0
    m.onHero = false
    m.loaded = false
    m.heroActions = []
    m.heroPlayingId = ""
    m.top.cardRect = [96, top() + 56, 854, 480]
end sub

sub onStatus()
    m.top.findNode("statusLabel").text = m.top.status
end sub

function hasHero() as Boolean
    return m.top.hero <> invalid and m.top.hero.id <> invalid
end function

' --- hero ---------------------------------------------------------------------------

sub onHero()
    v = m.top.hero
    if not hasHero()
        stopHero()
        m.heroGroup.visible = false
        if m.onHero then leaveHero(false)
        return
    end if
    ' A different video (or a refresh with new progress): start the 15 s again.
    if v.id <> m.heroPlayingId then stopHero()
    show = m.top.heroShow
    isEpisode = v.kind = "episode" and v.show <> invalid
    position = intOr(v.position, 0)
    title = "Untitled"
    if v.title <> invalid then title = v.title

    m.top.findNode("heroArt").uri = strOr(v.art)
    m.top.findNode("heroKicker").text = m.top.heroKicker
    logo = m.top.findNode("heroLogo")
    if isEpisode
        logo.text = v.show
    else
        logo.text = title
    end if
    logo.uri = strOr(v.logo)

    parts = []
    year = v.year
    if isEpisode and show <> invalid then year = show.year
    if year <> invalid then parts.Push(year.ToStr())
    if isEpisode and show <> invalid and intOr(show.season_count, 0) > 0
        n = intOr(show.season_count, 0)
        if n = 1
            parts.Push("1 Season")
        else
            parts.Push(n.ToStr() + " Seasons")
        end if
    end if
    if v.duration <> invalid and v.duration > 0 then parts.Push(Int((v.duration + 59) / 60).ToStr() + " min")
    m.top.findNode("heroMeta").text = parts.Join("   " + Chr(183) + "   ")
    episode = ""
    if isEpisode then episode = (episodeCode(v) + "  " + title).Trim()
    m.top.findNode("heroEpisode").text = episode
    ' The episode's synopsis, else the show's.
    desc = strOr(v.description)
    if desc = "" and isEpisode and show <> invalid then desc = strOr(show.description)
    m.top.findNode("heroDesc").text = desc

    progress = m.top.findNode("heroProgress")
    partWatched = position > 0 and v.watched <> true and intOr(v.duration, 0) > 0
    progress.visible = partWatched
    if partWatched then m.top.findNode("heroBar").width = Int(420 * position / v.duration)
    m.top.findNode("heroLeft").text = watchState(v)

    m.heroActions = []
    if partWatched
        m.heroActions.Push({ label: "Resume", action: "play", start: position, icon: "play" })
    else
        m.heroActions.Push({ label: "Play", action: "play", start: 0, icon: "play" })
    end if
    if isEpisode then m.heroActions.Push({ label: "Go to show", action: "show", icon: "episodes" })
    labels = []
    icons = []
    for each a in m.heroActions
        labels.Push(a.label)
        icons.Push("pkg:/images/icon_" + a.icon + ".png")
    end for
    m.heroButtons.icons = icons
    m.heroButtons.buttons = labels
    m.heroButtons.focusIndex = 0
    stackHeroLines()
    m.heroGroup.visible = m.onHero
    if m.onHero then scheduleHero()
end sub

' Each line under the one above, skipping empty ones; the buttons stay above the rows.
sub stackHeroLines()
    y = 196 + 240 + 20
    for each id in ["heroMeta", "heroEpisode", "heroDesc", "heroProgress"]
        node = m.top.findNode(id)
        shown = node.visible
        if id <> "heroProgress" then shown = node.text <> ""
        if shown
            if id = "heroProgress"
                node.translation = [96, y + 18]
                y = y + 56
            else
                node.translation = [96, y]
                y = y + Int(node.boundingRect().height) + 16
            end if
        end if
    end for
    if y > 760 then y = 760
    m.heroButtons.translation = [96, y + 12]
end sub

sub onHeroButton()
    a = m.heroActions[m.heroButtons.selected]
    m.top.heroAction = { action: a.action, start: a.start }
end sub

' The hero plays after 15 s, only while it has focus.
sub scheduleHero()
    if not m.onHero or not hasHero() or not m.top.isInFocusChain() then return
    if m.heroPlayingId = m.top.hero.id then return
    m.heroTimer.control = "stop"
    m.heroTimer.control = "start"
end sub

sub startHeroVideo()
    if not m.onHero or not hasHero() or not m.top.isInFocusChain() then return
    v = m.top.hero
    content = CreateObject("roSGNode", "ContentNode")
    content.url = v.url
    content.streamFormat = "mp4"
    if v.watched <> true and intOr(v.position, 0) > 0 then content.PlayStart = intOr(v.position, 0)
    m.heroPlayingId = v.id
    m.heroVideo.content = content
    m.heroVideo.control = "play"
end sub

sub onHeroVideoState()
    state = m.heroVideo.state
    ' Visible only once frames come, so the picture covers the loading time.
    if state = "playing" and m.heroPlayingId <> ""
        m.heroVideo.visible = true
    else if state = "finished" or state = "error"
        stopHero()
    end if
end sub

function stopHero(params = invalid as Dynamic) as Boolean
    m.heroTimer.control = "stop"
    if m.heroPlayingId <> ""
        m.heroPlayingId = ""
        m.heroVideo.control = "stop"
    end if
    m.heroVideo.visible = false
    return true
end function

sub onFocusChange()
    if not m.top.isInFocusChain()
        ' Another screen, the player or a menu took over.
        stopHero()
        return
    end if
    ' MainScene focuses this node; the hero's buttons take it from here.
    if m.top.hasFocus() and m.onHero then m.heroButtons.setFocus(true)
    scheduleHero()
end sub

sub enterHero()
    if not hasHero() then return
    if m.stack.getChildCount() > 0 then m.stack.getChild(m.rowIndex).active = false
    m.onHero = true
    m.top.heroFocused = true
    m.heroGroup.visible = true
    stackHeroLines()
    layoutRows(true)
    m.heroButtons.setFocus(true)
    m.top.focusedItem = invalid
    scheduleHero()
end sub

sub leaveHero(animate as Boolean)
    stopHero()
    m.onHero = false
    m.top.heroFocused = false
    m.heroGroup.visible = false
    if m.stack.getChildCount() = 0 then return
    m.rowIndex = 0
    m.stack.getChild(0).active = true
    layoutRows(animate)
    m.top.setFocus(true)
    m.top.focusedItem = currentItem()
end sub

' --- rows ---------------------------------------------------------------------------

' A card's identity across refreshes: the video id, or the show name.
function itemKey(item as Dynamic) as String
    if item = invalid then return ""
    if item.itemType = "show" then return "show:" + item.title
    return item.videoId
end function

sub onContent()
    ' Keep the place: same row (by title) and same card (by key) if they still exist.
    keepRow = ""
    keepKey = ""
    if m.stack.getChildCount() > 0
        row = m.stack.getChild(m.rowIndex)
        keepRow = row.content.title
        keepKey = itemKey(currentItem())
    end if

    m.stack.removeChildrenIndex(m.stack.getChildCount(), 0)
    content = m.top.content
    m.rowIndex = 0
    for i = 0 to content.getChildCount() - 1
        rowContent = content.getChild(i)
        row = m.stack.createChild("HomeRow")
        row.content = rowContent
        if rowContent.title = keepRow
            m.rowIndex = i
            for k = 0 to rowContent.getChildCount() - 1
                if itemKey(rowContent.getChild(k)) = keepKey then row.callFunc("jumpTo", k)
            end for
        end if
    end for
    ' The first load opens on the hero.
    if not m.loaded
        m.loaded = true
        m.onHero = hasHero()
    end if
    if m.onHero and not hasHero() then m.onHero = false
    m.top.heroFocused = m.onHero
    m.heroGroup.visible = m.onHero
    ' Text sizes are measured again now that the hero shows.
    if m.onHero then stackHeroLines()
    if m.stack.getChildCount() = 0
        m.top.focusedItem = invalid
        layoutRows(false)
        return
    end if
    m.stack.getChild(m.rowIndex).active = not m.onHero
    layoutRows(false)
    if m.onHero
        if m.top.isInFocusChain() then m.heroButtons.setFocus(true)
        m.top.focusedItem = invalid
    else
        m.top.focusedItem = currentItem()
    end if
end sub

function currentItem() as Dynamic
    if m.stack.getChildCount() = 0 or m.onHero then return invalid
    row = m.stack.getChild(m.rowIndex)
    return row.content.getChild(row.focusIndex)
end function

' Stack the rows. On the hero they peek under it; else the active row goes under the
' header and the rows above it hide.
sub layoutRows(animate as Boolean)
    m.top.findNode("headerBar").visible = not m.onHero
    y = 0
    activeY = 0
    for i = 0 to m.stack.getChildCount() - 1
        row = m.stack.getChild(i)
        if i = m.rowIndex then activeY = y
        row.translation = [0, y]
        row.visible = m.onHero or i >= m.rowIndex
        y = y + row.rowHeight
    end for
    if m.onHero
        target = [96, heroRowsTop()]
    else
        target = [96, top() - activeY]
    end if
    m.scrollAnim.control = "stop"
    if animate
        m.scrollTo.keyValue = [m.stack.translation, target]
        m.scrollAnim.control = "start"
    else
        m.stack.translation = target
    end if
end sub

sub selectRow(index as Integer)
    if index < 0 or index >= m.stack.getChildCount() or index = m.rowIndex then return
    m.stack.getChild(m.rowIndex).active = false
    m.rowIndex = index
    m.stack.getChild(m.rowIndex).active = true
    layoutRows(true)
    m.top.focusedItem = currentItem()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.onHero
        if key = "down" and m.stack.getChildCount() > 0
            leaveHero(true)
            return true
        else if key = "play"
            a = m.heroActions[0]
            m.top.heroAction = { action: a.action, start: a.start }
            return true
        end if
        ' Back on the hero leaves the channel; * goes to MainScene.
        return key = "up" or key = "left" or key = "right"
    end if
    if m.stack.getChildCount() = 0 then return false
    row = m.stack.getChild(m.rowIndex)
    if key = "up"
        if m.rowIndex = 0
            enterHero()
        else
            selectRow(m.rowIndex - 1)
        end if
        return true
    else if key = "down"
        selectRow(m.rowIndex + 1)
        return true
    else if key = "left" or key = "right"
        delta = 1
        if key = "left" then delta = -1
        if row.callFunc("moveFocus", delta) then m.top.focusedItem = currentItem()
        return true
    else if key = "OK"
        m.top.selectedItem = currentItem()
        return true
    else if key = "play"
        m.top.playItem = currentItem()
        return true
    else if key = "back"
        ' Back goes to the hero (or the first card); Back there leaves the channel.
        if hasHero()
            if row.focusIndex > 0 then row.callFunc("jumpTo", 0)
            enterHero()
            return true
        end if
        if m.rowIndex = 0 and row.focusIndex = 0 then return false
        if row.focusIndex > 0 then row.callFunc("moveFocus", -row.focusIndex)
        if m.rowIndex > 0
            first = m.stack.getChild(0)
            if first.focusIndex > 0 then first.callFunc("jumpTo", 0)
            selectRow(0)
        else
            m.top.focusedItem = currentItem()
        end if
        return true
    end if
    return false
end function
