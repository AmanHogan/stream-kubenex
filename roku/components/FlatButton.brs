sub init()
    m.bg = m.top.findNode("bg")
    m.label = m.top.findNode("label")
end sub

sub onText()
    m.label.width = 0
    m.label.text = m.top.text
    ' 40 px of room on each side of the text.
    w = Int(m.label.boundingRect().width) + 80
    if w < m.top.minWidth then w = m.top.minWidth
    m.bg.width = w
    m.label.width = w
    m.top.width = w
end sub

sub onHighlighted()
    if m.top.highlighted
        m.bg.blendColor = "0xFFFFFFFF"
        m.label.color = "0x111111FF"
    else
        m.bg.blendColor = "0x333333FF"
        m.label.color = "0xFFFFFFFF"
    end if
end sub
