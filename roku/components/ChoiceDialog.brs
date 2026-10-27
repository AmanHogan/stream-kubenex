sub init()
    m.list = m.top.findNode("list")
    m.list.observeField("itemSelected", "onItemSelected")
end sub

sub onTitle()
    m.top.findNode("titleLabel").text = m.top.title
end sub

sub onOptions()
    content = CreateObject("roSGNode", "ContentNode")
    for each text in m.top.options
        item = content.createChild("ContentNode")
        item.title = text
    end for
    m.list.content = content
end sub

function open(params = invalid as Dynamic) as Boolean
    m.top.visible = true
    m.list.jumpToItem = 0
    m.list.setFocus(true)
    return true
end function

sub onItemSelected()
    m.top.visible = false
    m.top.selected = m.list.itemSelected
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "back"
        m.top.visible = false
        m.top.cancelled = true
        return true
    end if
    ' Keep every other key inside the menu while it is open.
    return true
end function
