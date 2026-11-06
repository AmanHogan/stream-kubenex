' The active row's title is at y = top(); its expanded picture starts 56 px lower.
function top() as Integer
    return 120
end function

sub init()
    m.stack = m.top.findNode("stack")
    m.scrollAnim = m.top.findNode("scrollAnim")
    m.scrollTo = m.top.findNode("scrollTo")
    m.rowIndex = 0
    m.top.cardRect = [96, top() + 56, 854, 480]
end sub

sub onStatus()
    m.top.findNode("statusLabel").text = m.top.status
end sub

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
    if m.stack.getChildCount() = 0
        m.top.focusedItem = invalid
        return
    end if
    m.stack.getChild(m.rowIndex).active = true
    layoutRows(false)
    m.top.focusedItem = currentItem()
end sub

function currentItem() as Dynamic
    if m.stack.getChildCount() = 0 then return invalid
    row = m.stack.getChild(m.rowIndex)
    return row.content.getChild(row.focusIndex)
end function

' Stack the rows; the active one goes under the header. Rows above it hide.
sub layoutRows(animate as Boolean)
    y = 0
    activeY = 0
    for i = 0 to m.stack.getChildCount() - 1
        row = m.stack.getChild(i)
        if i = m.rowIndex then activeY = y
        row.translation = [0, y]
        row.visible = i >= m.rowIndex
        y = y + row.rowHeight
    end for
    target = [96, top() - activeY]
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
    if not press or m.stack.getChildCount() = 0 then return false
    row = m.stack.getChild(m.rowIndex)
    if key = "up"
        selectRow(m.rowIndex - 1)
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
        ' Back goes to the first card first; Back there leaves the channel.
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
