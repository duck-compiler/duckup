$ErrorActionPreference = "Stop"

$REPO = "duck-compiler/duckup"
$INSTALL_DIR = "$HOME\.duckup"
$BIN_DIR = "$INSTALL_DIR\bin"
$EXE_NAME = "duckup.exe"
$EXE_PATH = "$BIN_DIR\$EXE_NAME"

$E = [char]27
$C_RESET = "$E[0m"
$C_WHITE = "$E[97m"

$BG_DARGO = "$E[103;30m"
$BG_ERR   = "$E[41;97m"
$BG_SETUP = "$E[48;2;23;120;20;97m"
$BG_CHECK = "$E[42;97m"
$BG_IO    = "$E[48;2;23;120;20;97m"
$BG_ALERT = "$E[103;30m"

function Write-TagDuckup { Write-Host -NoNewline "$BG_DARGO duckup $C_RESET" }
function Write-TagSetup  { Write-TagDuckup; Write-Host "$BG_SETUP setup $C_RESET $($args[0])" }
function Write-TagError  { Write-TagDuckup; Write-Host "$BG_ERR error $C_RESET $($args[0])" }
function Write-TagCheck  { Write-TagDuckup; Write-Host "$BG_CHECK  ✓  $C_RESET $($args[0])" }
function Write-TagIO     { Write-TagDuckup; Write-Host "$BG_IO  IO   $C_RESET $($args[0])" }
function Write-TagAlert  { Write-TagDuckup; Write-Host "$BG_ALERT  !  $C_RESET $($args[0])" }

$ARCH = $env:PROCESSOR_ARCHITECTURE.ToLower()
$OS_TAG = "windows"

case ($ARCH) {
    "amd64" { $ARCH_TAG = "x86_64" }
    "arm64" { $ARCH_TAG = "aarch64" }
    default {
        Write-TagError "Unsupported Architecture: $ARCH"
        exit 1
    }
}

Write-TagSetup "Detecting latest nightly for $OS_TAG-$ARCH_TAG..."

try {
    $Releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases" -UseBasicParsing
    $LatestNightly = ($Releases | Where-Object { $_.tag_name -like "nightly-*" } | Select-Object -First 1)
} catch {
    Write-TagError "Failed to fetch releases."
    exit 1
}

if ($null -eq $LatestNightly) {
    Write-TagError "Could not find a 'nightly-*' tag in $REPO."
    exit 1
}

$Tag = $LatestNightly.tag_name
# Note: Windows binaries in your workflow are named duckup-windows-x86_64.exe
$AssetSuffix = if ($ARCH_TAG -eq "x86_64") { "x86_64" } else { "aarch64" }
$DownloadUrl = "https://github.com/$REPO/releases/download/$Tag/duckup-windows-$AssetSuffix.exe"

Write-TagIO "Downloading $EXE_NAME from $Tag..."

if (-not (Test-Path $BIN_DIR)) {
    New-Item -Path $BIN_DIR -ItemType Directory -Force | Out-Null
}

try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $EXE_PATH -UseBasicParsing
} catch {
    Write-TagError "Download failed. Verify that the asset 'duckup-windows-$AssetSuffix.exe' exists in the release."
    exit 1
}

Write-TagCheck "Successfully installed $EXE_NAME to $EXE_PATH"

$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$BIN_DIR*") {
    Write-TagSetup "Adding $BIN_DIR to PATH..."

    try {
        $NewPath = "$UserPath;$BIN_DIR"
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        $env:Path += ";$BIN_DIR"
        Write-TagCheck "User PATH updated successfully."
    } catch {
        Write-TagError "Failed to update PATH automatically."
    }

    Write-Host ""
    Write-TagAlert "To start using duckup, please restart your terminal or run:"
    Write-Host "  `$env:Path += ';$BIN_DIR'" -ForegroundColor White
}

Write-Host "`n---"
& $EXE_PATH --help
