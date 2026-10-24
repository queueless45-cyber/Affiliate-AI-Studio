$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/queueless45-cyber/Affiliate-AI-Studio.git"
$Branch = "affiliate-skills-integration"
$UserRoot = $env:USERPROFILE
$SearchRoots = @(
    (Join-Path $UserRoot "Downloads"),
    (Join-Path $UserRoot "Desktop"),
    (Join-Path $UserRoot "Affiliate-AI-Studio-GitHub"),
    (Join-Path $UserRoot "Affiliate-AI-Studio")
) | Where-Object { Test-Path -LiteralPath $_ }

function Test-ProjectZip([string]$Path) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            return ($archive.Entries.FullName -contains "Affiliate-AI-Studio-main/backend/app/main.py")
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        return $false
    }
}

$candidates = @()
foreach ($root in $SearchRoots) {
    $candidates += Get-ChildItem -LiteralPath $root -Filter "*.zip" -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Affiliate-AI-Studio-main*.zip" }
}
$Zip = $candidates |
    Where-Object { Test-ProjectZip $_.FullName } |
    Sort-Object -Property @{
        Expression = { if ($_.Name -eq "Affiliate-AI-Studio-main-verified.zip") { 0 } elseif ($_.Name -eq "Affiliate-AI-Studio-main(6).zip") { 1 } else { 2 } }
    }, @{
        Expression = { $_.LastWriteTime }
        Descending = $true
    } |
    Select-Object -First 1

if (-not $Zip) {
    Write-Host "Project ZIP not found." -ForegroundColor Red
    Write-Host "Download Affiliate-AI-Studio-main-verified.zip into your Downloads folder, then run this command again."
    exit 1
}
Write-Host "Using project ZIP: $($Zip.FullName)" -ForegroundColor Cyan

$WorkRoot = Join-Path $env:TEMP ("Affiliate-AI-Studio-import-" + [guid]::NewGuid().ToString("N"))
$RepoPath = Join-Path $WorkRoot "repo"
$ExtractPath = Join-Path $WorkRoot "extracted"
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or is not available in PATH."
    }

    Write-Host "Cloning your integration branch..." -ForegroundColor Cyan
    git clone --single-branch --branch $Branch $RepoUrl $RepoPath
    if ($LASTEXITCODE -ne 0) { throw "Git clone failed. Check GitHub access and try again." }

    Write-Host "Extracting the project ZIP..." -ForegroundColor Cyan
    Expand-Archive -LiteralPath $Zip.FullName -DestinationPath $ExtractPath -Force
    $SourceRoot = Join-Path $ExtractPath "Affiliate-AI-Studio-main"
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot "backend/app/main.py"))) {
        throw "The archive does not contain the expected backend/app/main.py file."
    }

    Get-ChildItem -LiteralPath $SourceRoot -Force -Recurse | ForEach-Object {
        $Relative = $_.FullName.Substring($SourceRoot.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
        $Destination = Join-Path $RepoPath $Relative
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        else {
            $DestinationFolder = Split-Path -Parent $Destination
            New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Force
        }
    }

    # This temporary import workflow is no longer needed once the project is copied locally.
    $TemporaryWorkflow = Join-Path $RepoPath ".github/workflows/import-project-archive.yml"
    if (Test-Path -LiteralPath $TemporaryWorkflow) {
        Remove-Item -LiteralPath $TemporaryWorkflow -Force
    }

    # Verify secrets and local databases are not included in the incoming project.
    $Forbidden = Get-ChildItem -LiteralPath $RepoPath -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq ".env" -or $_.Name -match '\.(db|sqlite|sqlite3)$' }
    if ($Forbidden) {
        $names = ($Forbidden | ForEach-Object { $_.FullName }) -join [Environment]::NewLine
        throw "Found a local secret/database file that must not be pushed: $names"
    }

    Push-Location $RepoPath
    try {
        Write-Host "Installing test dependencies..." -ForegroundColor Cyan
        python -m pip install -r requirements-dev.txt
        if ($LASTEXITCODE -ne 0) { throw "Dependency installation failed." }

        Write-Host "Running backend tests..." -ForegroundColor Cyan
        python -m pytest backend -q
        if ($LASTEXITCODE -ne 0) { throw "Tests failed. Nothing will be pushed." }

        git config user.name "queueless45-cyber"
        git config user.email "347410835+queueless45-cyber@users.noreply.github.com"
        git add -A
        $staged = @(git diff --cached --name-only)
        if ($staged | Where-Object { $_ -match '(^|/)\.env$|(^|/).+\.(db|sqlite|sqlite3)$' }) {
            throw "A secret or local database file is staged. Nothing will be pushed."
        }
        if ($staged.Count -eq 0) {
            Write-Host "No changes to push; the branch is already up to date." -ForegroundColor Yellow
            exit 0
        }

        git commit -m "Import full Affiliate AI Studio application source"
        if ($LASTEXITCODE -ne 0) { throw "Git commit failed." }

        Write-Host "Pushing the tested project to your GitHub branch..." -ForegroundColor Cyan
        git push origin "HEAD:$Branch"
        if ($LASTEXITCODE -ne 0) { throw "Push failed. Sign in to GitHub in Git Credential Manager, then rerun this script." }
    }
    finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "SUCCESS: Full project source pushed to:" -ForegroundColor Green
    Write-Host "https://github.com/queueless45-cyber/Affiliate-AI-Studio/tree/affiliate-skills-integration"
    Write-Host "The main branch was not overwritten."
}
catch {
    Write-Host "IMPORT STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "The temporary checkout is retained at: $WorkRoot"
    exit 1
}
