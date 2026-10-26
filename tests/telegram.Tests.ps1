# Unit tests for plugins/opaiva-code-widget/scripts/telegram.ps1, against a fake Bot API on localhost.
# Never the real api.telegram.org, never a real token.
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\telegram.ps1')
    . (Join-Path $PSScriptRoot 'helpers\FakeTelegram.ps1')
    $fake = Start-FakeTelegram
    $url = $fake.Url
    $token = '123456789:FAKE-token-for-tests'
    # The caught exception of a script block that must throw
    function Get-ThrownError([scriptblock]$Block) {
        try { & $Block } catch { return $_ }
        throw 'expected an error'
    }
}

AfterAll { Stop-FakeTelegram $fake }

Describe 'telegram.ps1' {
    BeforeEach {
        $fake.Requests.Clear()
        $fake.Replies.Clear()
    }

    It 'sends the text as UTF-8' {
        # "accion" with an accent, a check mark emoji and an n with tilde (the file must stay ASCII)
        $text = 'acci' + [char]0x00F3 + 'n ' + [char]::ConvertFromUtf32(0x2705) + ' ' + [char]0x00F1
        $fake.Replies['sendMessage'] = '{"ok":true,"result":{"message_id":777,"chat":{"id":42},"text":"x"}}'
        $id = Send-TelegramText -Token $token -Chat '42' -Text $text -BaseUrl $url
        $id | Should -Be 777
        $id | Should -BeOfType [int64]
        $req = @($fake.Requests)[0]
        $req.method | Should -BeExactly 'sendMessage'
        $req.contentType | Should -Match '^application/json; charset=utf-8$'
        $req.body.Contains($text) | Should -BeTrue
        $sent = $req.body | ConvertFrom-Json
        $sent.chat_id | Should -BeExactly '42'
        $sent.text | Should -BeExactly $text
        $sent.disable_web_page_preview | Should -BeTrue
        $sent.PSObject.Properties.Name | Should -Not -Contain 'parse_mode'
    }

    It 'throws TelegramError with status and description on ok:false' {
        $fake.Replies['getMe'] = @{ status = 401; body = '{"ok":false,"error_code":401,"description":"Unauthorized"}' }
        $err = Get-ThrownError { Get-TelegramBot -Token $token -BaseUrl $url }
        $err.Exception.Status | Should -Be 401
        $err.Exception.Status | Should -BeOfType [int]
        $err.Exception.Description | Should -BeExactly 'Unauthorized'
        $err.Exception.Message.Contains($token) | Should -BeFalse
        "$err".Contains($token) | Should -BeFalse
    }

    It 'throws TelegramError on ok:false even with HTTP 200' {
        $fake.Replies['getMe'] = '{"ok":false,"error_code":409,"description":"Conflict: webhook is active"}'
        $err = Get-ThrownError { Get-TelegramBot -Token $token -BaseUrl $url }
        $err.Exception.Status | Should -Be 409
        $err.Exception.Description | Should -BeExactly 'Conflict: webhook is active'
    }

    It 'times out' {
        $fake.Replies['sendMessage'] = @{ status = 200; body = '{"ok":true,"result":{"message_id":1}}'; delayMs = 3000 }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $err = Get-ThrownError { Send-TelegramText -Token $token -Chat '42' -Text 'hi' -BaseUrl $url -TimeoutSec 1 }
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 2
        $err.Exception.Status | Should -Be 0
        $err.Exception.Description | Should -Not -BeNullOrEmpty
        "$err".Contains($token) | Should -BeFalse
    }

    It 'Get-TelegramBot returns id, username and first_name' {
        $fake.Replies['getMe'] = '{"ok":true,"result":{"id":555,"is_bot":true,"first_name":"Widget","username":"my_widget_bot"}}'
        $bot = Get-TelegramBot -Token $token -BaseUrl $url
        $bot.id | Should -Be 555
        $bot.username | Should -BeExactly 'my_widget_bot'
        $bot.first_name | Should -BeExactly 'Widget'
        @($fake.Requests)[0].method | Should -BeExactly 'getMe'
    }

    It 'Edit-TelegramText calls editMessageText with the chat, message id and text' {
        $fake.Replies['editMessageText'] = '{"ok":true,"result":{"message_id":777}}'
        $out = Edit-TelegramText -Token $token -Chat '42' -MessageId 777 -Text 'done' -BaseUrl $url
        $out | Should -BeNullOrEmpty
        $req = @($fake.Requests)[0]
        $req.method | Should -BeExactly 'editMessageText'
        $sent = $req.body | ConvertFrom-Json
        $sent.chat_id | Should -BeExactly '42'
        $sent.message_id | Should -Be 777
        $sent.text | Should -BeExactly 'done'
    }

    It 'Find-TelegramStart ignores other messages and returns the chat of /start and the code' {
        $fake.Replies['getUpdates'] = '{"ok":true,"result":[' +
        '{"update_id":99,"my_chat_member":{"chat":{"id":7}}},' +
        '{"update_id":100,"message":{"message_id":1,"chat":{"id":7,"first_name":"Eve","type":"private"},"text":"/start wrong"}},' +
        '{"update_id":101,"message":{"message_id":2,"chat":{"id":7,"first_name":"Eve","type":"private"},"text":"hola"}},' +
        '{"update_id":102,"message":{"message_id":3,"chat":{"id":42,"first_name":"Daniel","type":"private"},"from":{"id":42,"first_name":"Daniel"},"text":"/start abc123"}}' +
        ']}'
        $found = Find-TelegramStart -Token $token -Code 'abc123' -Offset 0 -WaitSec 0 -BaseUrl $url
        $found.chat | Should -BeExactly '42'
        $found.name | Should -BeExactly 'Daniel'
        $found.offset | Should -Be 103
        $sent = @($fake.Requests)[0].body | ConvertFrom-Json
        $sent.offset | Should -Be 0
        $sent.timeout | Should -Be 0
    }

    It 'Find-TelegramStart returns $null when nothing matches' {
        $fake.Replies['getUpdates'] = '{"ok":true,"result":[' +
        '{"update_id":100,"message":{"message_id":1,"chat":{"id":7,"first_name":"Eve"},"text":"/start abc1234"}},' +
        '{"update_id":101,"message":{"message_id":2,"chat":{"id":7,"first_name":"Eve"},"text":"start abc123"}}' +
        ']}'
        Find-TelegramStart -Token $token -Code 'abc123' -Offset 0 -WaitSec 0 -BaseUrl $url | Should -BeNullOrEmpty
    }

    # Updates stay pending until a getUpdates asks past them: without moving the offset, a chat that
    # sent "hola" first would make every long poll return at once (a busy loop until /start arrives)
    It 'Find-TelegramStart polls again past the updates that did not match' {
        $fake.Replies['getUpdates'] = '{"ok":true,"result":[' +
        '{"update_id":100,"message":{"message_id":1,"chat":{"id":7,"first_name":"Eve"},"text":"hola"}},' +
        '{"update_id":101,"message":{"message_id":2,"chat":{"id":7,"first_name":"Eve"},"text":"/start wrong"}}' +
        ']}'
        Find-TelegramStart -Token $token -Code 'abc123' -Offset 50 -WaitSec 5 -BaseUrl $url | Should -BeNullOrEmpty
        $polls = @($fake.Requests | Where-Object { $_.method -eq 'getUpdates' })
        $polls.Count | Should -Be 2
        ($polls[0].body | ConvertFrom-Json).offset | Should -Be 50
        ($polls[0].body | ConvertFrom-Json).timeout | Should -Be 5
        ($polls[1].body | ConvertFrom-Json).offset | Should -Be 102
    }
}
