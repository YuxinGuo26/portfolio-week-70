$root = "c:\Users\Administrator\Desktop\Trae"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8080/")
$listener.Start()
Write-Host "Serving on http://localhost:8080/ — press Ctrl+C to stop"

$mime = @{
  ".html" = "text/html; charset=utf-8"
  ".css"  = "text/css; charset=utf-8"
  ".js"   = "application/javascript; charset=utf-8"
  ".json" = "application/json; charset=utf-8"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".svg"  = "image/svg+xml"
  ".ico"  = "image/x-icon"
}

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response

    $path = $req.Url.AbsolutePath.TrimStart("/")
    if ($path -eq "") { $path = "index.html" }
    $file = Join-Path $root $path

    # Same-origin proxy for the UAPI weather endpoint.
    # The browser hits /weather-api?city=...&forecast=true&lang=en; this
    # server performs the actual HTTPS request, so browser-side
    # CORS/network blips never block the app. Status codes and JSON bodies
    # are relayed unchanged (the raw, percent-encoded query is forwarded).
    if ($path -eq "weather-api") {
      $city = $req.QueryString["city"]
      $res.ContentType = "application/json; charset=utf-8"

      if ([string]::IsNullOrWhiteSpace($city)) {
        $res.StatusCode = 400
        $eb = [System.Text.Encoding]::UTF8.GetBytes('{"code":"INVALID_PARAMETER","message":"city required"}')
        $res.ContentLength64 = $eb.Length
        $res.OutputStream.Write($eb, 0, $eb.Length)
        $res.Close()
        continue
      }

      $apiUrl = "https://uapis.cn/api/v1/misc/weather" + $req.Url.Query
      try {
        # HttpClient (unlike Invoke-WebRequest) keeps the response body for
        # non-2xx responses, so 404 LOCATION_NOT_FOUND is relayed intact.
        Add-Type -AssemblyName System.Net.Http
        $handler = New-Object System.Net.Http.HttpClientHandler
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $apiResp = $client.GetAsync($apiUrl).GetAwaiter().GetResult()
        $bytes = $apiResp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $res.StatusCode = [int]$apiResp.StatusCode
        $client.Dispose()
      } catch {
        # Server could not reach the upstream at all (DNS / TLS / timeout)
        $res.StatusCode = 502
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"UPSTREAM_UNREACHABLE"}')
      }
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.Close()
      continue
    }

    if (Test-Path $file -PathType Leaf) {
      $ext = [System.IO.Path]::GetExtension($file).ToLower()
      $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
      $res.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
      $bytes = [System.IO.File]::ReadAllBytes($file)
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $res.StatusCode = 404
      $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $path")
      $res.OutputStream.Write($msg, 0, $msg.Length)
    }
    $res.Close()
  } catch {
    Write-Host "Error: $_"
  }
}
