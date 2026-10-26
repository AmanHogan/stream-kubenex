sub init()
    m.top.functionName = "load"
end sub

sub load()
    server = CreateObject("roAppInfo").GetValue("server_url")
    port = CreateObject("roMessagePort")
    http = CreateObject("roUrlTransfer")
    http.SetMessagePort(port)
    http.SetUrl(server + "/api/library")

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
    if json = invalid or json.shows = invalid
        m.top.error = "bad JSON from " + server
        return
    end if

    root = CreateObject("roSGNode", "ContentNode")
    addVideoRow(root, "Recently added", json.recent)
    addShowRow(root, json.shows)
    addVideoRow(root, "Movies", json.movies)
    addVideoRow(root, "Clips", json.clips)
    m.top.library = json
    m.top.rows = root
end sub

' One row of playable videos. Empty lists add no row.
sub addVideoRow(root as Object, title as String, videos as Object)
    if videos = invalid or videos.Count() = 0 then return
    row = root.createChild("ContentNode")
    row.title = title
    for each v in videos
        item = row.createChild("ContentNode")
        fillVideoItem(item, v)
    end for
end sub

' One card per show. Selecting it opens the show screen; showIndex points into library.shows.
sub addShowRow(root as Object, shows as Object)
    if shows = invalid or shows.Count() = 0 then return
    row = root.createChild("ContentNode")
    row.title = "TV Shows"
    for i = 0 to shows.Count() - 1
        s = shows[i]
        item = row.createChild("ContentNode")
        item.addFields({ itemType: "show", showIndex: i, videoId: "" })
        item.title = s.name
        item.HDPOSTERURL = s.thumbnail
        count = s.episode_count
        if count = 1
            item.SHORTDESCRIPTIONLINE2 = "1 episode"
        else
            item.SHORTDESCRIPTIONLINE2 = count.ToStr() + " episodes"
        end if
    end for
end sub
