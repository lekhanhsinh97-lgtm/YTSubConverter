$script:ErrorActionPreference = "Stop"

# Example:
# $args="https://www.youtube.com/watch?v=-GaV5ouXOOw"

# Prepare local working directories for the temporary download and final output.
$rootPath = (Get-Location).Path
$tempPath = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
$outputPath = Join-Path $rootPath "output"
$tempResultPath = Join-Path $tempPath "result"

# Define the paths to the required executables.
$ytdlpPath = "yt-dlp"
$ytSubConverter = "$rootPath\YTSubConverter.exe"
$ffmpegPath = "ffmpeg"

# Keep all downloaded media and converted subtitle files in a temporary workspace
# so the final output can be moved cleanly into the project's output folder.
New-Item -ItemType Directory -Force -Path $tempResultPath | Out-Null
try {
    # Download the video with all subtitle tracks (in .srv3 format), using the best
    # available video/audio stream and storing the files in the temp folder.
    $ytDlpArgs = $args + @(
        " -f", "bestvideo+bestaudio/best",
        "--write-subs", 
        "--sub-format", "srv3",
        "--sub-langs", "all",
        "--embed-thumbnail", 
        "--merge-output-format", "mkv", 
        "-P", "$tempPath",
        "-o", "`"%(title)s [%(id)s].%(ext)s`"")
    Start-Process `
        -FilePath "$ytdlpPath" `
        -ArgumentList $ytDlpArgs `
        -Wait `
        -NoNewWindow

    # Group each downloaded MKV file with any subtitle files that match its base name.
    # If no subtitle file exists, keep the original video in the result folder as-is.
    $videoGroups = @()
    Get-ChildItem -Path $tempPath -Filter "*.mkv" -File |
    Where-Object { $_.DirectoryName -ne $tempResultPath } | ForEach-Object {
        $subtitleGroups = Get-ChildItem -Path $tempPath -Filter "$($_.BaseName).*.srv3" -File
        if ($subtitleGroups.Count -eq 0) {
            Move-Item -LiteralPath $_.FullName -Destination (Join-Path $tempResultPath $_.Name)
        }
        $videoGroups += [pscustomobject]@{
            Video    = $_
            Subtitle = $subtitleGroups
        }
    }

    # Convert each subtitle track to ASS format using the bundled converter and then
    # re-mux the converted subtitle files into the original video.
    foreach ($group in $videoGroups) {
        $videoName = $group.Video.BaseName
        $videoPath = Join-Path $tempPath "$videoName.mkv"
        $convertedSubs = @()

        foreach ($subtitle in $group.Subtitle) {
            $assPath = Join-Path $tempPath "$($subtitle.BaseName).ass"
            Start-Process `
                -FilePath "$ytSubConverter" `
                -ArgumentList @(
                "`"$($subtitle.FullName)`"",
                "`"$assPath`"",
                "--visual"
            ) `
                -Wait `
                -NoNewWindow

            # Only keep subtitles that were successfully converted.
            if (Test-Path -LiteralPath $assPath) {
                $convertedSubs += [pscustomobject]@{
                    AssPath  = $assPath
                    Subtitle = $subtitle
                }
            }
        }

        # Skip videos that do not have any converted subtitle tracks.
        if ($convertedSubs.Count -eq 0) {
            continue
        }

        # Build the ffmpeg command that maps original video/audio streams and adds all
        # subtitle streams as extra tracks with language metadata.
        $ffmpegArgs = @("-y", "-i", "`"$videoPath`"")

        foreach ($item in $convertedSubs) {
            $ffmpegArgs += @("-i", "`"$($item.AssPath)`"")
        }

        $ffmpegArgs += @(
            "-analyzeduration", "2147483647",
            "-probesize", "2147483647",
            "-map", "0:v?",
            "-map", "0:a?",
            "-map", "0:d?",
            "-map", "0:t?")

        for ($i = 0; $i -lt $convertedSubs.Count; $i++) {
            $ffmpegArgs += @("-map", "$($i + 1):0")
        }

        $ffmpegArgs += @("-c", "copy")

        for ($i = 0; $i -lt $convertedSubs.Count; $i++) {
            $subtitle = $convertedSubs[$i].Subtitle
            $languageTag = $subtitle.BaseName.Substring(
                $subtitle.BaseName.LastIndexOf('.') + 1
            )
            $languageCode = $languageTag.Split('-')[0].ToLowerInvariant()

            # Resolve the language name from the ISO code so ffmpeg metadata is readable.
            $language = python -c "import pycountry; lang=pycountry.languages.get(alpha_2='$languageCode'); print(lang.name if lang else '$languageCode')"
            
            $regionCode = $languageTag.Split('-')[1]
            if ($regionCode) { 
                $language += " - $regionCode" 
            }

            $ffmpegArgs += @(
                "-metadata:s:s:$i", "language=$languageCode",
                "-metadata:s:s:$i", "title=$language"
            )
        }

        # Write the final muxed MKV into the temporary result folder.
        $ffmpegArgs += "`"$(Join-Path $tempResultPath "$videoName.mkv")`""

        # Only mux the file when the original video is present in the temp workspace.
        if (Test-Path -LiteralPath $videoPath) {
            Start-Process `
                -FilePath "$ffmpegPath" `
                -ArgumentList $ffmpegArgs `
                -Wait `
                -NoNewWindow
        }
        
    }
}
catch {
    Write-Warning "$_"
}
finally {
    # Ensure the output directory exists and move all finished files out of the temp
    # workspace, then remove the temporary folder used for the download and conversion.
    if (-not (Test-Path $outputPath)) {
        New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    }

    if (Test-Path $tempResultPath) {
        Move-Item -Path (Join-Path $tempResultPath "*") -Destination $outputPath -Force
    }
    Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
}