sub init()
    m.items = m.top.findNode("items")
    ' The highlight shows only while this row has focus.
    m.top.observeField("focusedChild", "showHighlight")
end sub

sub onButtons()
    m.items.removeChildrenIndex(m.items.getChildCount(), 0)
    icons = m.top.icons
    widest = 0
    for i = 0 to m.top.buttons.Count() - 1
        b = m.items.createChild("FlatButton")
        b.minWidth = m.top.minWidth
        if icons <> invalid and i < icons.Count() then b.icon = icons[i]
        b.text = m.top.buttons[i]
        if b.width > widest then widest = b.width
    end for
    ' A column: every button as wide as the widest. A row: side by side.
    offset = 0
    for i = 0 to m.items.getChildCount() - 1
        b = m.items.getChild(i)
        if m.top.vertical
            b.minWidth = widest
            b.translation = [0, offset]
            offset = offset + 72 + m.top.spacing
        else
            b.translation = [offset, 0]
            offset = offset + b.width + m.top.spacing
        end if
    end for
    if m.top.focusIndex >= m.items.getChildCount() then m.top.focusIndex = 0
    showHighlight()
end sub

sub showHighlight()
    focused = m.top.isInFocusChain()
    for i = 0 to m.items.getChildCount() - 1
        m.items.getChild(i).highlighted = focused and i = m.top.focusIndex
    end for
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    count = m.items.getChildCount()
    back = "left"
    forward = "right"
    if m.top.vertical
        back = "up"
        forward = "down"
    end if
    if key = back and m.top.focusIndex > 0
        m.top.focusIndex = m.top.focusIndex - 1
        return true
    else if key = forward and m.top.focusIndex < count - 1
        m.top.focusIndex = m.top.focusIndex + 1
        return true
    else if key = "OK" and count > 0
        m.top.selected = m.top.focusIndex
        return true
    end if
    ' The first and last buttons stop the arrows too. A single button (Skip intro,
    ' Play now) lets them through, so the player can seek.
    return count > 1 and (key = back or key = forward)
end function
