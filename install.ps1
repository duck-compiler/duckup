$ErrorActionPreference = "Stop"

$REPO = "duck-compiler/duckup"
$BINARY_BASE_NAME = "duckup"
$EXE_NAME = "duckup.exe"

$DATA_DIR = Join-Path $env:LOCALAPPDATA "duck-compiler\duckup"
$BIN_DIR = Join-Path $DATA_DIR "bin"
$EXE_PATH = Join-Path $BIN_DIR $EXE_NAME

$GLOBAL_DUCK = Join-Path $HOME ".duck"
$TOOLCHAIN_DIR = Join-Path $DATA_DIR "toolchains"
$CACHE_DIR = Join-Path $DATA_DIR "cache"

$E = [char]27
$C_RESET = "$E[0m"
$C_WHITE = "$E[97m"
$BG_DARGO = "$E[103;30m"
$BG_ERR   = "$E[41;97m"
$BG_SETUP = "$E[48;2;23;120;20;97m"
$BG_CHECK = "$E[42;97m"
$BG_IO    = "$E[48;2;23;120;20;97m"
$BG_ALERT = "$E[103;30m"

function Write-TagDargo { Write-Host -NoNewline "$BG_DARGO duckup $C_RESET" }
function Write-TagSetup  { Write-TagDargo; Write-Host "$BG_SETUP setup $C_RESET $($args[0])" }
function Write-TagError  { Write-TagDargo; Write-Host "$BG_ERR error $C_RESET $($args[0])" }
function Write-TagCheck  { Write-TagDargo; Write-Host "$BG_CHECK  ✓  $C_RESET $($args[0])" }
function Write-TagIO     { Write-TagDargo; Write-Host "$BG_IO  IO   $C_RESET $($args[0])" }
function Write-TagAlert  { Write-TagDargo; Write-Host "$BG_ALERT  !  $C_RESET $($args[0])" }

New-Item -Path $BIN_DIR, $TOOLCHAIN_DIR, $CACHE_DIR, $GLOBAL_DUCK -ItemType Directory -Force | Out-Null

$ARCH_RAW = $env:PROCESSOR_ARCHITECTURE.ToLower()
$OS_TAG = "windows"
$ARCH_TAG = if ($ARCH_RAW -eq "amd64") { "x86_64" } else { "aarch64" }

Write-TagSetup "Detecting latest nightly for $OS_TAG-$ARCH_TAG..."

try {
    $Releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases" -UseBasicParsing
    $LatestNightly = ($Releases | Where-Object { $_.tag_name -match "nightly-\d{8}-[a-z0-9]{7}" } | Select-Object -First 1)
} catch {
    Write-TagError "Failed to fetch releases from GitHub."
    exit 1
}

if ($null -eq $LatestNightly) {
    Write-TagError "Could not find a valid nightly tag (nightly-YYYYMMDD-hash) in $REPO."
    exit 1
}

$Tag = $LatestNightly.tag_name
$TargetFileName = "${BINARY_BASE_NAME}-${OS_TAG}-${ARCH_TAG}.exe"
$DownloadUrl = "https://github.com/$REPO/releases/download/$Tag/$TargetFileName"

Write-TagIO "Downloading $EXE_NAME from $Tag..."

try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $EXE_PATH -UseBasicParsing
} catch {
    Write-TagError "Download failed. Asset '$TargetFileName' not found in release $Tag."
    exit 1
}

Write-TagCheck "Successfully installed $EXE_NAME to $EXE_PATH"
Write-TagCheck "Initialized configuration at $GLOBAL_DUCK"

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
# Ausführung des installierten Binaries
& $EXE_PATH --help
