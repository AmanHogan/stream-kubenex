sub init()
    m.bg = m.top.findNode("bg")
    m.glyph = m.top.findNode("glyph")
    m.label = m.top.findNode("label")
end sub

sub layout()
    hasIcon = m.top.icon <> ""
    m.glyph.visible = hasIcon
    m.glyph.uri = m.top.icon
    m.label.width = 0
    m.label.text = m.top.text
    textWidth = Int(m.label.boundingRect().width)
    ' 40 px of room on each side; with an icon, the text starts after it.
    left = 40
    if hasIcon then left = 84
    w = left + textWidth + 40
    if w < m.top.minWidth then w = m.top.minWidth
    m.bg.width = w
    if hasIcon
        m.label.horizAlign = "left"
        m.label.translation = [left, 0]
        m.label.width = w - left - 20
    else
        m.label.horizAlign = "center"
        m.label.translation = [0, 0]
        m.label.width = w
    end if
    m.top.width = w
end sub

sub onHighlighted()
    if m.top.highlighted
        m.bg.blendColor = "0xFFFFFFFF"
        m.label.color = "0x111111FF"
        m.glyph.blendColor = "0x111111FF"
    else
        m.bg.blendColor = "0x333333FF"
        m.label.color = "0xFFFFFFFF"
        m.glyph.blendColor = "0xFFFFFFFF"
    end if
end sub
