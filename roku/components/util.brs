' Helpers shared by LibraryTask, ShowScreen and MainScene.

' Copies one video from /api/library into a ContentNode the cards and the player can use.
sub fillVideoItem(item as Object, v as Object)
    title = "Untitled"
    if v.title <> invalid then title = v.title
    item.addFields({ itemType: "video", showIndex: -1, videoId: v.id,
        progressPos: intOr(v.position, 0), lengthSec: intOr(v.duration, 0), isWatched: v.watched = true })
    item.title = title
    item.url = v.url
    item.HDPOSTERURL = v.thumbnail
    item.HDGRIDPOSTERURL = v.thumbnail
    item.SHORTDESCRIPTIONLINE1 = title
    item.SHORTDESCRIPTIONLINE2 = videoSubtitle(v)
end sub

' "The Office  S2 E5  -  12 min left" for episodes, "2010  -  2:28:00" for movies.
' The last part is the watch state: "Watched", "N min left", or the length.
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
    state = watchState(v)
    if state <> "" then parts.Push(state)
    return parts.Join("  -  ")
end function

function watchState(v as Object) as String
    if v.watched = true then return "Watched"
    if v.remaining <> invalid and intOr(v.position, 0) > 0
        return Int((v.remaining + 59) / 60).ToStr() + " min left"
    end if
    return formatDuration(v.duration)
end function

' "S1 E12  Title", or just the title for anything that is not an episode.
function episodeLabel(v as Object) as String
    label = ""
    if v.season <> invalid then label = "S" + v.season.ToStr() + " "
    if v.episode <> invalid then label = label + "E" + v.episode.ToStr() + "  "
    if v.title <> invalid then label = label + v.title
    return label
end function

' JSON null arrives as invalid; numbers may arrive as Integer or Double.
function intOr(value as Dynamic, fallback as Integer) as Integer
    if value = invalid then return fallback
    return Int(value)
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
