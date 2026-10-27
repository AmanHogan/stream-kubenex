sub init()
    m.top.functionName = "serve"
end sub

sub serve()
    server = CreateObject("roAppInfo").GetValue("server_url")
    port = CreateObject("roMessagePort")
    m.top.observeField("request", port)
    done = 0
    while true
        msg = wait(0, port)
        if type(msg) = "roSGNodeEvent" and msg.getField() = "request"
            req = msg.getData()
            post(server + req.path, FormatJson(req.body))
            done = done + 1
            m.top.completed = done
        end if
    end while
end sub

' Best effort: a lost progress update only costs a few seconds of resume position.
sub post(url as String, body as String)
    port = CreateObject("roMessagePort")
    http = CreateObject("roUrlTransfer")
    http.SetMessagePort(port)
    http.SetUrl(url)
    http.AddHeader("Content-Type", "application/json")
    if http.AsyncPostFromString(body)
        msg = wait(5000, port)
        if type(msg) <> "roUrlEvent" then http.AsyncCancel()
    end if
end sub
