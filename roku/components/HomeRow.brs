' Card sizes (see HomeCard): small 512x288, expanded 960x540.
function layout() as Object
    return { small: 512, big: 960, gap: 32, titleHeight: 56,
        activeHeight: 56 + 540 + 150, restHeight: 56 + 288 + 64 }
end function

sub init()
    m.L = layout()
    m.strip = m.top.findNode("strip")
    m.slideAnim = m.top.findNode("slideAnim")
    m.slideTo = m.top.findNode("slideTo")
    m.slideAnim.observeField("state", "onSlideState")
    m.top.rowHeight = m.L.restHeight
end sub

sub onContent()
    content = m.top.content
    m.top.findNode("title").text = content.title
    m.strip.removeChildrenIndex(m.strip.getChildCount(), 0)
    for i = 0 to content.getChildCount() - 1
        card = m.strip.createChild("HomeCard")
        card.itemContent = content.getChild(i)
    end for
    if m.top.focusIndex >= content.getChildCount() then m.top.focusIndex = 0
    place(false)
end sub

sub onActive()
    if m.top.active
        m.top.rowHeight = m.L.activeHeight
    else
        m.top.rowHeight = m.L.restHeight
    end if
    place(true)
end sub

' x of card k when card f is selected. Cards after an expanded card move right by
' the extra width it takes.
function cardX(k as Integer, f as Integer) as Integer
    pitch = m.L.small + m.L.gap
    x = k * pitch
    if m.top.active and k > f then x = x + m.L.big - m.L.small
    return x
end function

sub place(animate as Boolean)
    f = m.top.focusIndex
    count = m.strip.getChildCount()
    for k = 0 to count - 1
        card = m.strip.getChild(k)
        card.animate = animate
        card.x = cardX(k, f)
        card.expanded = m.top.active and k = f
        ' Cards to the left of the selection are off screen; cards far right too.
        card.visible = (k >= f - 1 and k <= f + 4)
    end for
    target = [-f * (m.L.small + m.L.gap), 0]
    m.slideAnim.control = "stop"
    if animate
        m.slideTo.keyValue = [m.strip.translation, target]
        m.slideAnim.control = "start"
    else
        m.strip.translation = target
        hideLeft()
    end if
end sub

sub onSlideState()
    if m.slideAnim.state = "stopped" then hideLeft()
end sub

' The card that just slid out on the left stays visible while it slides; hide it after.
sub hideLeft()
    f = m.top.focusIndex
    for k = 0 to f - 1
        m.strip.getChild(k).visible = false
    end for
end sub

function moveFocus(delta as Integer) as Boolean
    f = m.top.focusIndex + delta
    if f < 0 or f >= m.strip.getChildCount() then return false
    m.top.focusIndex = f
    place(true)
    return true
end function

function jumpTo(index as Integer) as Boolean
    if index < 0 or index >= m.strip.getChildCount() then index = 0
    m.top.focusIndex = index
    place(false)
    return true
end function
