function Convert-WinUtilTextEncoding {
    param([AllowNull()][object]$Text)

    # Windows PowerShell 5.1 reads UTF-8 scripts without a BOM as ANSI. This
    # can corrupt string literals when a source file is dot-sourced directly.
    # Only repair the typical UTF-8-as-Windows-1252 markers in UI strings.
    if ($Text -isnot [string] -or [string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.IndexOf([char]0x00C3) -lt 0 -and
        $Text.IndexOf([char]0x00C2) -lt 0 -and
        $Text.IndexOf([char]0x00E2) -lt 0) {
        return $Text
    }

    try {
        $windows1252 = [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $restored = $utf8.GetString($windows1252.GetBytes($Text))
        if ($restored -ne $Text) { return $restored }
    } catch [Text.EncoderFallbackException] {
        # Normal Unicode outside code page 1252 is not mojibake.
    } catch [Text.DecoderFallbackException] {
        # An invalid UTF-8 sequence is evidence that the original text was fine.
    }
    return $Text
}
