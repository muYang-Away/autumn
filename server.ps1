param(
    [int]$Port = 8000,
    [string]$Root = "."
)

$Root = [System.IO.Path]::GetFullPath($Root)

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Serving $Root at $prefix"

$types = @{
    ".html" = "text/html; charset=utf-8"
    ".htm"  = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
    ".txt"  = "text/plain; charset=utf-8"
    ".webp" = "image/webp"
    ".woff" = "font/woff"
    ".woff2" = "font/woff2"
    ".ttf"  = "font/ttf"
    ".mp3"  = "audio/mpeg"
    ".ogg"  = "audio/ogg"
    ".wav"  = "audio/wav"
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()

        $urlPath = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($urlPath) -or $urlPath.EndsWith("/")) {
            $urlPath = $urlPath.TrimEnd("/") + "/index.html"
        }
        $relative = $urlPath.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
        $filePath = Join-Path $Root $relative

        if (-not (Test-Path -LiteralPath $filePath)) {
            $context.Response.StatusCode = 404
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
            continue
        }

        $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
        $contentType = $types[$ext]
        if (-not $contentType) { $contentType = "application/octet-stream" }

        $context.Response.ContentType = $contentType
        $fileInfo = Get-Item -LiteralPath $filePath
        $length = [int64]$fileInfo.Length
        $rangeHeader = $context.Request.Headers["Range"]
        $context.Response.Headers["Accept-Ranges"] = "bytes"

        if ($rangeHeader) {
            $m = [regex]::Match($rangeHeader, "bytes=(\d*)-(\d*)")
            $startStr = $m.Groups[1].Value
            $endStr = $m.Groups[2].Value
            if ([string]::IsNullOrEmpty($startStr) -and -not [string]::IsNullOrEmpty($endStr)) {
                $endVal = [int64]$endStr
                $start = [int64]([math]::Max(0, $length - $endVal))
                $end = $length - 1
            } else {
                $start = if ([string]::IsNullOrEmpty($startStr)) { 0 } else { [int64]$startStr }
                $end = if ([string]::IsNullOrEmpty($endStr)) { $length - 1 } else { [int64]$endStr }
            }

            if ($start -ge $length -or $end -lt $start) {
                $context.Response.StatusCode = 416
                $context.Response.Headers["Content-Range"] = "bytes */$length"
                $context.Response.Close()
                continue
            }

            $chunkLen = ($end - $start + 1)
            $context.Response.StatusCode = 206
            $context.Response.Headers["Content-Range"] = "bytes $start-$end/$length"
            $context.Response.ContentLength64 = $chunkLen

            $fs = [System.IO.File]::OpenRead($filePath)
            try {
                $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
                $buffer = New-Object byte[] 65536
                $remaining = $chunkLen
                while ($remaining -gt 0) {
                    $read = $fs.Read($buffer, 0, [int][math]::Min($buffer.Length, $remaining))
                    if ($read -le 0) { break }
                    $context.Response.OutputStream.Write($buffer, 0, $read)
                    $remaining -= $read
                }
            } finally {
                $fs.Dispose()
                $context.Response.Close()
            }
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $context.Response.StatusCode = 200
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
        }
    } catch {
        try { $context.Response.StatusCode = 500; $context.Response.Close() } catch {}
    }
}