param(
    [ValidateRange(1024, 65000)][int]$Port = 8321,
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$siteRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if (-not (Test-Path -LiteralPath (Join-Path $siteRoot 'index.html') -PathType Leaf)) {
    throw 'Please extract the complete ZIP before running this launcher.'
}
$listener = $null
for ($candidatePort = $Port; $candidatePort -lt ($Port + 20); $candidatePort++) {
    try {
        $candidateListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidatePort)
        $candidateListener.Start()
        $listener = $candidateListener
        $sitePort = $candidatePort
        break
    } catch [Net.Sockets.SocketException] {
        if ($candidateListener) { $candidateListener.Stop() }
    }
}
if (-not $listener) { throw "No available local port between $Port and $($Port + 19)." }
$url = "http://127.0.0.1:$sitePort/"
$mimeTypes = @{
    '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8';
    '.css'='text/css; charset=utf-8'; '.json'='application/json; charset=utf-8';
    '.svg'='image/svg+xml'; '.woff2'='font/woff2'; '.woff'='font/woff';
    '.png'='image/png'; '.ico'='image/x-icon'; '.webp'='image/webp';
    '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.txt'='text/plain; charset=utf-8'
}
function Send-SiteResponse {
    param($Stream, [int]$Status, [string]$Reason, [string]$ContentType, [byte[]]$Body, [bool]$HeadOnly)
    $responseHeader = "HTTP/1.1 $Status $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($responseHeader)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}
Write-Host ''
Write-Host 'CB ATLAS - local static website' -ForegroundColor Green
Write-Host "Open: $url"
Write-Host 'Keep this window open. Close it or press Ctrl+C to stop.'
Write-Host 'This server listens only on 127.0.0.1 and does not update market data.'
Write-Host ''
if (-not $NoBrowser) { Start-Process -FilePath $url }
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 10000
            $client.SendTimeout = 30000
            $stream = $client.GetStream()
            $stream.ReadTimeout = 10000
            $stream.WriteTimeout = 30000
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
            $requestLine = $reader.ReadLine()
            if (-not $requestLine -or $requestLine.Length -gt 8192) { continue }
            $parts = $requestLine.Split(' ')
            if ($parts.Length -ne 3) { continue }
            $headerLength = 0
            while ($true) {
                $headerLine = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($headerLine)) { break }
                $headerLength += $headerLine.Length
                if ($headerLength -gt 32768) { throw 'Request headers too large.' }
            }
            $method = $parts[0]
            $isHead = $method -eq 'HEAD'
            if ($method -ne 'GET' -and -not $isHead) {
                Send-SiteResponse $stream 405 'Method Not Allowed' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('GET and HEAD only.')) $false
                continue
            }
            $requestPath = [Uri]::UnescapeDataString(($parts[1] -split '[?#]', 2)[0])
            if (-not $requestPath.StartsWith('/') -or $requestPath.Contains('\') -or $requestPath.Contains(':') -or $requestPath.Contains([char]0)) {
                Send-SiteResponse $stream 400 'Bad Request' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Invalid path.')) $isHead
                continue
            }
            if ($requestPath -eq '/') { $requestPath = '/index.html' }
            $filePath = [IO.Path]::GetFullPath((Join-Path $siteRoot $requestPath.TrimStart('/')))
            $rootPrefix = $siteRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $filePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Send-SiteResponse $stream 403 'Forbidden' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Path is outside the website.')) $isHead
                continue
            }
            $extension = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
            if (-not $mimeTypes.ContainsKey($extension) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                Send-SiteResponse $stream 404 'Not Found' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('File not found.')) $isHead
                continue
            }
            $body = [IO.File]::ReadAllBytes($filePath)
            Send-SiteResponse $stream 200 'OK' $mimeTypes[$extension] $body $isHead
        } catch {
            # Closing or refreshing a browser can cancel a connection. Keep serving.
        } finally {
            if ($reader) { $reader.Dispose(); $reader = $null }
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
