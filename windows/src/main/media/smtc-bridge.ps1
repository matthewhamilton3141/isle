# smtc-bridge.ps1
#
# The Windows counterpart of the Mac app's mediaremote-adapter: a long-lived
# child process that reads the system's now-playing state and streams it back
# to Isle as JSON lines on stdout, and accepts transport commands as lines on
# stdin.
#
# Why PowerShell: Windows PowerShell 5.1 (present on every Windows 10/11
# install) can project WinRT types directly, so this reaches
# GlobalSystemMediaTransportControlsSessionManager — the same API the media
# keys, the volume flyout and the lock screen use — with no native build step,
# no node-gyp, and nothing to compile. Isle never links anything; it just
# spawns this script and talks to it over pipes.
#
# Protocol (one JSON object per line):
#   -> {"type":"ready"}
#   -> {"type":"np", hasTrack, title, artist, album, status, position,
#        duration, lastUpdated, shuffle, repeat, artKey, art?, artMime?,
#        canSeek, canShuffle, canRepeat, appId}
#   -> {"type":"error", message}
#   <- playpause | play | pause | next | prev | seek <seconds>
#      | shuffle <0|1> | repeat <none|list|track> | quit
#
# Scoped to Spotify: of every media session Windows knows about, the one whose
# app id names Spotify is the one reported. A browser tab or another player is
# ignored, exactly as the Mac app ignores anything that isn't Spotify.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Runtime.WindowsRuntime

# Touching a WinRT type by its full projection name is what loads the
# projection; the results are discarded on purpose.
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
$null = [Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType=WindowsRuntime]

# WinRT async operations have to be bridged to .NET Tasks to be awaited from
# PowerShell. `AsTask<T>(IAsyncOperation<T>)` is generic, so it's resolved by
# reflection once and instantiated per result type.
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($operation, $resultType) {
    $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($operation))
    $task.Wait(-1) | Out-Null
    return $task.Result
}

function Emit($object) {
    $json = $object | ConvertTo-Json -Compress -Depth 4
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Emit-Error($message) {
    Emit @{ type = 'error'; message = "$message" }
}

$manager = $null
try {
    $manager = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
        ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
} catch {
    Emit-Error "SMTC manager unavailable: $($_.Exception.Message)"
    exit 1
}

Emit @{ type = 'ready' }

# The Spotify session, or $null. Both the desktop client (Spotify.exe) and the
# Store build (SpotifyAB.SpotifyMusic_...!Spotify) carry the name.
function Find-SpotifySession {
    foreach ($session in $manager.GetSessions()) {
        $id = $session.SourceAppUserModelId
        if ($id -and $id.ToLowerInvariant().Contains('spotify')) { return $session }
    }
    return $null
}

# Reads a thumbnail stream to base64.
#
# The opened stream comes back to PowerShell as an opaque __ComObject: the
# projection can't see the interface members on it, so `$ras.Size` is empty
# and the AsStreamForRead overload never binds. Going through reflection on the
# interface types makes the runtime QI the object itself, which works.
$contentTypeProperty = [Windows.Storage.Streams.IContentTypeProvider].GetProperty('ContentType')
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod(
    'AsStreamForRead', [type[]]@([Windows.Storage.Streams.IInputStream]))

function Read-Thumbnail($thumbnail) {
    if (-not $thumbnail) { return $null }
    try {
        $ras = Await ($thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
        $mime = [string]$contentTypeProperty.GetValue($ras)
        $net = $asStreamForRead.Invoke($null, @($ras))
        $memory = New-Object System.IO.MemoryStream
        $net.CopyTo($memory)
        $bytes = $memory.ToArray()
        $net.Dispose(); $memory.Dispose()
        if ($bytes.Length -eq 0) { return $null }
        return @{ mime = $mime; data = [Convert]::ToBase64String($bytes) }
    } catch {
        return $null
    }
}

$lastKey = ''
$lastArtKey = ''

# One poll: read the Spotify session and emit a snapshot if anything the app
# draws has changed. Artwork rides along only when the track changes — it's
# the one expensive field, and the client caches it by artKey.
function Poll {
    $session = Find-SpotifySession
    if (-not $session) {
        $snapshot = @{ type = 'np'; hasTrack = $false }
        $key = 'none'
        if ($key -ne $script:lastKey) {
            $script:lastKey = $key
            $script:lastArtKey = ''
            Emit $snapshot
        }
        return
    }

    $props = $null
    try {
        $props = Await ($session.TryGetMediaPropertiesAsync()) `
            ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    } catch { }
    $playback = $session.GetPlaybackInfo()
    $timeline = $session.GetTimelineProperties()
    $controls = $playback.Controls

    $title = if ($props) { [string]$props.Title } else { '' }
    $artist = if ($props) { [string]$props.Artist } else { '' }
    $album = if ($props) { [string]$props.AlbumTitle } else { '' }

    $status = [string]$playback.PlaybackStatus
    $shuffle = $playback.IsShuffleActive        # Nullable<bool>
    $repeat = $playback.AutoRepeatMode          # Nullable<MediaPlaybackAutoRepeatMode>
    $repeatName = if ($repeat -ne $null) { ([string]$repeat).ToLowerInvariant() } else { $null }

    $position = [math]::Round($timeline.Position.TotalSeconds, 3)
    $duration = [math]::Round(($timeline.EndTime - $timeline.StartTime).TotalSeconds, 3)
    $lastUpdated = $timeline.LastUpdatedTime.ToUnixTimeMilliseconds()

    $artKey = "$title|$artist|$album"
    $hasTrack = ($title.Length -gt 0)

    $snapshot = [ordered]@{
        type = 'np'
        hasTrack = $hasTrack
        appId = [string]$session.SourceAppUserModelId
        title = $title
        artist = $artist
        album = $album
        status = $status
        position = $position
        duration = $duration
        lastUpdated = $lastUpdated
        shuffle = $shuffle
        repeat = $repeatName
        artKey = $artKey
        canSeek = [bool]$controls.IsPlaybackPositionEnabled
        canShuffle = [bool]$controls.IsShuffleEnabled
        canRepeat = [bool]$controls.IsRepeatEnabled
    }

    # Change detection excludes nothing: position moves as Spotify reports it,
    # which is the poll's whole job. The client smooths the clock itself.
    $key = "$hasTrack|$title|$artist|$album|$status|$position|$duration|$lastUpdated|$shuffle|$repeatName"
    if ($key -eq $script:lastKey) { return }
    $script:lastKey = $key

    if ($hasTrack -and $artKey -ne $script:lastArtKey) {
        $art = Read-Thumbnail $props.Thumbnail
        if ($art) {
            $snapshot['art'] = $art.data
            $snapshot['artMime'] = $art.mime
            $script:lastArtKey = $artKey
        } else {
            # No bytes yet (Spotify attaches the cover a beat after the
            # metadata): leave the key unset so the next poll tries again.
            $script:lastArtKey = ''
        }
    }

    Emit $snapshot
}

function Handle-Command($line) {
    $parts = $line.Trim() -split '\s+', 2
    $verb = $parts[0].ToLowerInvariant()
    $arg = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    if ($verb -eq 'quit') { exit 0 }

    $session = Find-SpotifySession
    if (-not $session) { return }
    try {
        switch ($verb) {
            'playpause' { $null = Await ($session.TryTogglePlayPauseAsync()) ([bool]) }
            'play'      { $null = Await ($session.TryPlayAsync()) ([bool]) }
            'pause'     { $null = Await ($session.TryPauseAsync()) ([bool]) }
            'next'      { $null = Await ($session.TrySkipNextAsync()) ([bool]) }
            'prev'      { $null = Await ($session.TrySkipPreviousAsync()) ([bool]) }
            'seek' {
                $seconds = [double]$arg
                if ($seconds -lt 0) { $seconds = 0 }
                $ticks = [int64]($seconds * 10000000)
                $null = Await ($session.TryChangePlaybackPositionAsync($ticks)) ([bool])
            }
            'shuffle' {
                $on = ($arg -eq '1' -or $arg -eq 'true')
                $null = Await ($session.TryChangeShuffleActiveAsync($on)) ([bool])
            }
            'repeat' {
                $mode = switch ($arg.ToLowerInvariant()) {
                    'list'  { [Windows.Media.MediaPlaybackAutoRepeatMode]::List }
                    'track' { [Windows.Media.MediaPlaybackAutoRepeatMode]::Track }
                    default { [Windows.Media.MediaPlaybackAutoRepeatMode]::None }
                }
                $null = Await ($session.TryChangeAutoRepeatModeAsync($mode)) ([bool])
            }
        }
    } catch {
        Emit-Error "command '$line' failed: $($_.Exception.Message)"
    }
    # Re-read straight away so the island confirms the command promptly rather
    # than on the next scheduled poll.
    $script:pollDue = 0
}

# Commands arrive on stdin. Read from the raw stream with ReadAsync rather
# than Console.In.ReadLineAsync: on .NET Framework the latter is synchronous
# in disguise and would block the poll loop until a line arrived. A zero-byte
# read means the pipe closed — the parent is gone — and the bridge exits with
# it rather than lingering as an orphan.
$stdinStream = [Console]::OpenStandardInput()
$stdinBuffer = New-Object byte[] 4096
$stdinText = New-Object System.Text.StringBuilder
$pending = $stdinStream.ReadAsync($stdinBuffer, 0, $stdinBuffer.Length)

$pollInterval = 250
$script:pollDue = 0
# A Stopwatch rather than Environment.TickCount: TickCount64 isn't on .NET
# Framework (PowerShell returns $null for it, silently), and the 32-bit one
# wraps negative after 25 days.
$clock = [System.Diagnostics.Stopwatch]::StartNew()

while ($true) {
    if ($pending.IsCompleted) {
        $count = $pending.Result
        if ($count -le 0) { exit 0 }
        $null = $stdinText.Append([System.Text.Encoding]::UTF8.GetString($stdinBuffer, 0, $count))
        $text = $stdinText.ToString()
        $newline = $text.IndexOf("`n")
        while ($newline -ge 0) {
            $line = $text.Substring(0, $newline).Trim()
            $text = $text.Substring($newline + 1)
            if ($line.Length -gt 0) { Handle-Command $line }
            $newline = $text.IndexOf("`n")
        }
        $null = $stdinText.Clear().Append($text)
        $pending = $stdinStream.ReadAsync($stdinBuffer, 0, $stdinBuffer.Length)
    }

    $now = $clock.ElapsedMilliseconds
    if ($now -ge $script:pollDue) {
        try { Poll } catch { Emit-Error "poll failed: $($_.Exception.Message)" }
        $script:pollDue = $now + $pollInterval
    }

    Start-Sleep -Milliseconds 40
}
