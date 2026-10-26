sub onContent()
    item = m.top.itemContent
    m.top.findNode("poster").uri = item.HDPOSTERURL
    m.top.findNode("title").text = item.title
    m.top.findNode("sub").text = item.SHORTDESCRIPTIONLINE2
end sub
