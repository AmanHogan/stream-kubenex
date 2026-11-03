sub init()
    m.items = m.top.findNode("items")
    ' The highlight shows only while this row has focus.
    m.top.observeField("focusedChild", "showHighlight")
end sub

sub onButtons()
    m.items.removeChildrenIndex(m.items.getChildCount(), 0)
    x = 0
    for each text in m.top.buttons
        b = m.items.createChild("FlatButton")
        b.minWidth = m.top.minWidth
        b.text = text
        b.translation = [x, 0]
        x = x + b.width + m.top.spacing
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
    if key = "left" and m.top.focusIndex > 0
        m.top.focusIndex = m.top.focusIndex - 1
        return true
    else if key = "right" and m.top.focusIndex < count - 1
        m.top.focusIndex = m.top.focusIndex + 1
        return true
    else if key = "OK" and count > 0
        m.top.selected = m.top.focusIndex
        return true
    end if
    ' Left on the first button and Right on the last stop here too. A single button
    ' (Skip intro, Play now) lets them through, so the player can seek.
    return count > 1 and (key = "left" or key = "right")
end function
