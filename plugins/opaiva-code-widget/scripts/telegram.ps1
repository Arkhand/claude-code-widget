# Telegram Bot API client. This is the ONLY plugin file allowed to use the network, and only to
# reach the Telegram Bot API. Every call blocks for up to TimeoutSec: run it off the UI thread.
# -BaseUrl exists so the tests can point at a fake local Bot API; production keeps the default.
# The token is part of the URL, so neither the URL nor the token ever goes into an error or a log.

# A failed call: Status is Telegram's error_code (or the HTTP status), 0 when there was no answer
# (timeout, no network); Description is Telegram's description or the network error.
class TelegramError : System.Exception {
    [int]$Status
    [string]$Description
    TelegramError([int]$Status, [string]$Description) : base("Telegram API error ${Status}: $Description") {
        $this.Status = $Status
        $this.Description = $Description
    }
}

# Defensive: no error text from .NET should carry the token, but never let one through
function Hide-TelegramToken([string]$Text, [string]$Token) {
    if ($Token -and $Text) { return $Text.Replace($Token, '<token>') }
    return $Text
}

# POSTs $Body as UTF-8 JSON to <BaseUrl>/bot<Token>/<Method> and returns Telegram's "result".
function Invoke-TelegramApi([string]$Token, [string]$Method, [hashtable]$Body = @{},
    [string]$BaseUrl = 'https://api.telegram.org', [int]$TimeoutSec = 10) {
    # Windows PowerShell 5.1 may not offer TLS 1.2 by default, and Telegram requires it
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes(($Body | ConvertTo-Json -Depth 5 -Compress))
    # HttpWebRequest instead of Invoke-RestMethod: it has a real timeout and gives the body of a 4xx reply
    try {
        $req = [Net.WebRequest]::Create("$($BaseUrl.TrimEnd('/'))/bot$Token/$Method")
        $req.Method = 'POST'
        $req.ContentType = 'application/json; charset=utf-8'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
        $resp = $req.GetResponse()
    }
    catch {
        $ex = $_.Exception
        while ($ex -and $ex -isnot [Net.WebException]) { $ex = $ex.InnerException }
        if (-not $ex -or -not $ex.Response) {
            $why = if ($ex) { "$($ex.Status): $($ex.Message)" } else { $_.Exception.Message }
            throw [TelegramError]::new(0, (Hide-TelegramToken $why $Token))
        }
        # Telegram answers errors with 4xx and a JSON body: read it like a normal reply
        $resp = $ex.Response
    }
    try {
        $status = [int]$resp.StatusCode
        $statusText = [string]$resp.StatusDescription
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
    }
    catch { throw [TelegramError]::new(0, (Hide-TelegramToken $_.Exception.Message $Token)) }
    finally { $resp.Close() }
    $reply = $null
    try { $reply = $text | ConvertFrom-Json } catch {}
    if ($reply -and $reply.ok -eq $true) { return $reply.result }
    $code = if ($reply -and $reply.error_code) { [int]$reply.error_code } else { $status }
    $desc = if ($reply -and $reply.description) { [string]$reply.description } else { $statusText }
    throw [TelegramError]::new($code, (Hide-TelegramToken $desc $Token))
}

# getMe: checks the token and tells the bot's name
function Get-TelegramBot([string]$Token, [string]$BaseUrl = 'https://api.telegram.org', [int]$TimeoutSec = 10) {
    $r = Invoke-TelegramApi $Token 'getMe' @{} -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec
    return @{ id = [int64]$r.id; username = [string]$r.username; first_name = [string]$r.first_name }
}

# Plain text (no parse_mode: project and file names must not be read as markup). Returns the message id.
function Send-TelegramText([string]$Token, [string]$Chat, [string]$Text,
    [string]$BaseUrl = 'https://api.telegram.org', [int]$TimeoutSec = 10) {
    $r = Invoke-TelegramApi $Token 'sendMessage' @{ chat_id = $Chat; text = $Text; disable_web_page_preview = $true } -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec
    return [int64]$r.message_id
}

function Edit-TelegramText([string]$Token, [string]$Chat, [int64]$MessageId, [string]$Text,
    [string]$BaseUrl = 'https://api.telegram.org', [int]$TimeoutSec = 10) {
    [void](Invoke-TelegramApi $Token 'editMessageText' @{ chat_id = $Chat; message_id = $MessageId; text = $Text; disable_web_page_preview = $true } -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec)
}

# Long-polls getUpdates for up to WaitSec until a message reads exactly "/start <Code>".
# Returns @{ chat; name; offset } (offset: the next update id to ask for) or $null.
# Updates that do not match are skipped by asking past them: Telegram keeps an update pending until
# a getUpdates asks for a later id, and a pending one would make every long poll return at once.
function Find-TelegramStart([string]$Token, [string]$Code, [int64]$Offset, [int]$WaitSec,
    [string]$BaseUrl = 'https://api.telegram.org', [int]$TimeoutSec = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSec)
    $wait = $WaitSec
    while ($true) {
        # The HTTP timeout covers the long poll plus the usual margin
        $updates = @(Invoke-TelegramApi $Token 'getUpdates' @{ offset = $Offset; timeout = $wait } -BaseUrl $BaseUrl -TimeoutSec ($TimeoutSec + $wait))
        if ($updates.Count -eq 0) { return $null }
        foreach ($u in $updates) {
            $Offset = [int64]$u.update_id + 1
            $m = $u.message
            if ($m -and [string]$m.text -ceq "/start $Code") {
                $name = @($m.chat.first_name, $m.from.first_name, $m.chat.title) | Where-Object { $_ } | Select-Object -First 1
                return @{ chat = [string]$m.chat.id; name = [string]$name; offset = $Offset }
            }
        }
        $wait = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        if ($wait -le 0) { return $null }
    }
}
