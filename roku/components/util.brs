' Helpers shared by LibraryTask and ShowScreen.

' Copies one video from /api/library into a ContentNode the cards and the player can use.
sub fillVideoItem(item as Object, v as Object)
    title = "Untitled"
    if v.title <> invalid then title = v.title
    item.addFields({ itemType: "video", showIndex: -1, videoId: v.id })
    item.title = title
    item.url = v.url
    item.HDPOSTERURL = v.thumbnail
    item.HDGRIDPOSTERURL = v.thumbnail
    item.SHORTDESCRIPTIONLINE1 = title
    item.SHORTDESCRIPTIONLINE2 = videoSubtitle(v)
end sub

' "The Office  S2 E5  -  22:31" for episodes, "2010  -  2:28:00" for movies, else the length.
function videoSubtitle(v as Object) as String
    parts = []
    if v.kind = "episode"
        where = ""
        if v.show <> invalid then where = v.show
        if v.season <> invalid then where = where + "  S" + v.season.ToStr()
        if v.episode <> invalid then where = where + " E" + v.episode.ToStr()
        if where <> "" then parts.Push(where)
    else if v.kind = "movie" and v.year <> invalid
        parts.Push(v.year.ToStr())
    end if
    length = formatDuration(v.duration)
    if length <> "" then parts.Push(length)
    return parts.Join("  -  ")
end function

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
