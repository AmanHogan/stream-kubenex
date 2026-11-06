sub init()
    m.label = m.top.findNode("label")
    m.poster = m.top.findNode("poster")
    m.poster.observeField("loadStatus", "onLoad")
end sub

sub onText()
    m.label.width = m.top.maxWidth
    m.label.text = m.top.text
    h = Int(m.label.boundingRect().height)
    m.label.translation = [0, m.top.maxHeight - h]
end sub

sub onUri()
    m.poster.visible = false
    m.label.visible = true
    m.poster.uri = m.top.uri
end sub

sub onLoad()
    if m.poster.loadStatus <> "ready" or m.top.uri = "" then return
    bw = m.poster.bitmapWidth
    bh = m.poster.bitmapHeight
    if bw <= 0 or bh <= 0 then return
    ' Fit inside the box without stretching; never make a small logo bigger than 1.5x.
    s = m.top.maxWidth / bw
    if m.top.maxHeight / bh < s then s = m.top.maxHeight / bh
    if s > 1.5 then s = 1.5
    w = Int(bw * s)
    h = Int(bh * s)
    m.poster.width = w
    m.poster.height = h
    m.poster.translation = [0, m.top.maxHeight - h]
    m.poster.visible = true
    m.label.visible = false
end sub
