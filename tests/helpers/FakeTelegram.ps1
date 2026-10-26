# A fake Telegram Bot API for the tests: a local HttpListener that answers POST /bot<token>/<method>.
# Replies[method] is the JSON text to answer with (status 200) or @{ status; body; delayMs }.
# A method without a reply gets 404, like Telegram does for unknown methods.
# Requests records each call as @{ method; token (from the URL); body (the request body decoded as UTF-8); contentType }.
# getUpdates replies drop the updates below the request's offset, as Telegram drops confirmed ones.

function Start-FakeTelegram {
    $requests = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    $replies = [hashtable]::Synchronized(@{})
    $l = $null
    for ($try = 0; $try -lt 30 -and -not $l; $try++) {
        $port = Get-Random -Minimum 20000 -Maximum 60000
        $cand = New-Object System.Net.HttpListener
        $cand.Prefixes.Add("http://127.0.0.1:$port/")
        try { $cand.Start(); $l = $cand } catch { $cand.Close() }
    }
    if (-not $l) { throw 'no free port for the fake Telegram' }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($l, $requests, $replies)
            $enc = New-Object Text.UTF8Encoding $false
            while ($l.IsListening) {
                try { $ctx = $l.GetContext() } catch { break }
                try {
                    $reader = New-Object IO.StreamReader($ctx.Request.InputStream, $enc)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                    $method = ''
                    $token = ''
                    if ($ctx.Request.Url.AbsolutePath -match '^/bot([^/]+)/([^/]+)$') { $token = [Uri]::UnescapeDataString($Matches[1]); $method = $Matches[2] }
                    # Recorded before answering, so a test that got its reply always sees its request
                    [void]$requests.Add(@{ method = $method; token = $token; body = $body; contentType = $ctx.Request.ContentType })
                    $status = 200
                    $delay = 0
                    $reply = $replies[$method]
                    if ($reply -is [hashtable]) {
                        if ($reply.status) { $status = [int]$reply.status }
                        $delay = [int]$reply.delayMs
                        $text = [string]$reply.body
                    }
                    elseif ($reply) { $text = [string]$reply }
                    else { $status = 404; $text = '{"ok":false,"error_code":404,"description":"Not Found"}' }
                    if ($method -eq 'getUpdates' -and $status -eq 200 -and $body) {
                        $offset = [int64]($body | ConvertFrom-Json).offset
                        $obj = $text | ConvertFrom-Json
                        $obj.result = @(@($obj.result) | Where-Object { [int64]$_.update_id -ge $offset })
                        $text = $obj | ConvertTo-Json -Depth 10 -Compress
                    }
                    if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
                    $bytes = $enc.GetBytes($text)
                    $ctx.Response.StatusCode = $status
                    $ctx.Response.ContentType = 'application/json'
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $ctx.Response.Close()
                }
                catch { try { $ctx.Response.Abort() } catch {} }
            }
        }).AddArgument($l).AddArgument($requests).AddArgument($replies)
    $handle = $ps.BeginInvoke()
    return @{ Url = "http://127.0.0.1:$port"; Listener = $l; Ps = $ps; Handle = $handle; Requests = $requests; Replies = $replies }
}

function Stop-FakeTelegram($Fake) {
    try { $Fake.Listener.Stop(); $Fake.Listener.Close() } catch {}
    try { $Fake.Ps.Dispose() } catch {}
}
