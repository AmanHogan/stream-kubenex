sub init()
    m.top.functionName = "load"
end sub

sub load()
    server = CreateObject("roAppInfo").GetValue("server_url")
    port = CreateObject("roMessagePort")
    http = CreateObject("roUrlTransfer")
    http.SetMessagePort(port)
    http.SetUrl(server + "/api/feed")

    body = invalid
    if http.AsyncGetToString()
        msg = wait(10000, port)
        if type(msg) = "roUrlEvent" and msg.GetResponseCode() = 200
            body = msg.GetString()
        else
            http.AsyncCancel()
        end if
    end if
    if body = invalid
        m.top.error = "no response from " + server
        return
    end if

    json = ParseJson(body)
    if json = invalid or json.videos = invalid
        m.top.error = "bad JSON from " + server
        return
    end if

    root = CreateObject("roSGNode", "ContentNode")
    for each v in json.videos
        item = root.createChild("ContentNode")
        title = "Untitled"
        if v.title <> invalid then title = v.title
        item.title = title
        item.url = v.url
        item.HDGRIDPOSTERURL = v.thumbnail
        item.SDGRIDPOSTERURL = v.thumbnail
        item.SHORTDESCRIPTIONLINE1 = title
        item.SHORTDESCRIPTIONLINE2 = formatDuration(v.duration)
    end for
    m.top.content = root
end sub

function formatDuration(seconds as Dynamic) as String
    if seconds = invalid or seconds = 0 then return ""
    hours = Int(seconds / 3600)
    mins = Int((seconds MOD 3600) / 60)
    secs = seconds MOD 60
    out = ""
    if hours > 0
        out = hours.ToStr() + ":"
        if mins < 10 then out = out + "0"
    end if
    out = out + mins.ToStr() + ":"
    if secs < 10 then out = out + "0"
    return out + secs.ToStr()
end function
