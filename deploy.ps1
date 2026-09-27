<#
Deploy website company profile ke VPS (https://company.gladhy.tech).

Pemakaian (dari folder ini, di PowerShell):
  .\deploy.ps1              # paket + upload + cek
  .\deploy.ps1 -BuildOnly   # hanya membuat paket di folder dist\, tanpa upload
  .\deploy.ps1 -Rollback    # kembalikan versi sebelum deploy terakhir

Catatan server:
  - Caddy (container gladhy-caddy-1) membaca /opt/company-web lewat bind mount
    direktori. Isi folder diganti DI TEMPAT, bukan folder yang di-mv, karena
    bind mount menempel ke folder lama dan Caddy tidak akan melihat folder baru.
  - Tidak perlu restart Caddy; file statis langsung terbaca.
#>
param(
    [switch]$BuildOnly,
    [switch]$Rollback,
    [string]$Server = "root@187.124.137.5",
    [string]$Key = "$env:USERPROFILE\.ssh\id_ed25519_gladhy",
    [string]$Url = "https://company.gladhy.tech"
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Src = Join-Path $Root "Smart Teknologi Kreasi website"
$Page = "Smart Teknologi Kreasi v2.dc.html"
$Dist = Join-Path $Root "dist"
$Remote = "/opt/company-web"
$SshOpts = @("-i", $Key, "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=20")

function Invoke-Remote([string]$Cmd) {
    # Buang CR: file ini bisa ber-CRLF di Windows, dan bash menolak "set -e`r".
    $Cmd = $Cmd -replace "`r", ""
    & ssh @SshOpts $Server $Cmd
    if ($LASTEXITCODE -ne 0) { throw "Perintah di server gagal (exit $LASTEXITCODE)." }
}

function Test-Site {
    Write-Host "Cek $Url ..."
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
        if ($r.StatusCode -eq 200 -and $r.Content -match "<title>") {
            Write-Host "OK: $Url merespons 200." -ForegroundColor Green
        } else {
            Write-Warning "Respons tidak terduga: $($r.StatusCode)"
        }
    } catch {
        Write-Warning "Situs tidak bisa dibuka: $($_.Exception.Message)"
    }
}

if ($Rollback) {
    Write-Host "Mengembalikan versi sebelumnya dari $Remote.prev ..."
    Invoke-Remote "set -e; test -d $Remote.prev || { echo 'Tidak ada $Remote.prev'; exit 1; }; find $Remote -mindepth 1 -delete; cp -a $Remote.prev/. $Remote/"
    Test-Site
    return
}

# 1. Peringatan kalau ada perubahan yang belum di-commit
if (Get-Command git -ErrorAction SilentlyContinue) {
    $dirty = git -C $Root status --porcelain
    if ($dirty) { Write-Warning "Ada perubahan yang belum di-commit; tetap di-deploy apa adanya." }
}

# 2. Susun paket: halaman v2 menjadi index.html, plus hanya aset yang dipakai
Write-Host "Menyusun paket di $Dist ..."
if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Path (Join-Path $Dist "assets") -Force | Out-Null

$html = Get-Content (Join-Path $Src $Page) -Raw -Encoding UTF8
Copy-Item (Join-Path $Src $Page) (Join-Path $Dist "index.html")
Copy-Item (Join-Path $Src "support.js") $Dist
Copy-Item (Join-Path $Src "_ds") $Dist -Recurse

$assets = [regex]::Matches($html, 'assets/[A-Za-z0-9_.\-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique
foreach ($a in $assets) {
    $p = Join-Path $Src $a
    if (-not (Test-Path $p)) { throw "Aset dirujuk di halaman tapi tidak ada: $a" }
    Copy-Item $p (Join-Path $Dist "assets")
}
Write-Host ("  {0} aset: {1}" -f $assets.Count, (($assets | ForEach-Object { Split-Path $_ -Leaf }) -join ", "))

if ($BuildOnly) {
    Write-Host "Selesai (BuildOnly). Paket ada di $Dist" -ForegroundColor Green
    return
}

# 3. Kemas dan upload. Lewat file + scp, bukan pipe, karena PowerShell 5.1
#    merusak data biner yang di-pipe ke program lain.
$Tgz = Join-Path $env:TEMP "company-web.tgz"
if (Test-Path $Tgz) { Remove-Item $Tgz -Force -Confirm:$false }
& tar.exe -czf $Tgz -C $Dist .
if ($LASTEXITCODE -ne 0) { throw "Gagal membuat arsip." }

Write-Host "Upload ke $Server ..."
& scp @SshOpts $Tgz "${Server}:/tmp/company-web.tgz"
if ($LASTEXITCODE -ne 0) { throw "Upload gagal." }
Remove-Item $Tgz -Force -Confirm:$false

# 4. Di server: ekstrak ke folder sementara, simpan versi lama ke .prev,
#    lalu ganti isi folder yang di-mount di tempat.
Write-Host "Memasang di server ..."
Invoke-Remote @"
set -e
rm -rf $Remote.new && mkdir -p $Remote.new
tar -xzf /tmp/company-web.tgz -C $Remote.new
rm -f /tmp/company-web.tgz
test -f $Remote.new/index.html
chmod -R a+rX $Remote.new
rm -rf $Remote.prev && cp -a $Remote $Remote.prev
find $Remote -mindepth 1 -delete
cp -a $Remote.new/. $Remote/
rm -rf $Remote.new
echo "Terpasang: `$(find $Remote -type f | wc -l) file"
"@

Test-Site
