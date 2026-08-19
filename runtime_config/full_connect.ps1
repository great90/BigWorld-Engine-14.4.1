# Full client startup and connection flow
# Starts client, logs in, creates character, and enters game world

$wshell = New-Object -ComObject wscript.shell

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function TakeScreenshot($path) {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
    $bitmap.Save($path)
    $graphics.Dispose()
    $bitmap.Dispose()
}

function Activate($waitMs) {
    $wshell.AppActivate('BigWorld Client Hybrid Version') | Out-Null
    Start-Sleep -Milliseconds $waitMs
}

$ssDir = "j:\Work\BigWorld-Engine-14.4.1\game\bin\client\win64"
$clientExe = "$ssDir\bwclient_h.exe"

# Kill any existing client
Get-Process bwclient_h -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

# Start client with -noConversion flag
Write-Host "Starting client..."
Set-Location $ssDir
Start-Process $clientExe -ArgumentList "-noConversion" -WorkingDirectory $ssDir
Start-Sleep -Seconds 12

TakeScreenshot "$ssDir\fc_step1_menu.png"
Write-Host "Step 1: Main menu screenshot taken"

# Step 2: Press Enter to select "Connect to Standard Server..."
Write-Host "Step 2: Connecting to server..."
Activate 500
$wshell.SendKeys('{ENTER}')
Start-Sleep -Seconds 3
TakeScreenshot "$ssDir\fc_step2_username.png"

# Step 3: Press Enter to confirm username (empty = default)
Write-Host "Step 3: Confirming username..."
Activate 500
$wshell.SendKeys('{ENTER}')
Start-Sleep -Seconds 5
TakeScreenshot "$ssDir\fc_step3_realm.png"

# Step 4: Press Enter to select Fantasy Realm
Write-Host "Step 4: Selecting realm..."
Activate 500
$wshell.SendKeys('{ENTER}')
Start-Sleep -Seconds 5
TakeScreenshot "$ssDir\fc_step4_charsel.png"

# Step 5: At character selection. No characters exist, so <Create Character> is highlighted.
# Press Enter to create character
Write-Host "Step 5: Creating character..."
Activate 500
$wshell.SendKeys('{ENTER}')
Start-Sleep -Seconds 3
TakeScreenshot "$ssDir\fc_step5_charname.png"

# Step 6: Type character name and press Enter
# The text field might be empty or have old text. Clear it first.
Write-Host "Step 6: Entering character name..."
Activate 500
# Clear any existing text
$wshell.SendKeys('^a')
Start-Sleep -Milliseconds 200
$wshell.SendKeys('{DELETE}')
Start-Sleep -Milliseconds 200
# Type character name "hero"
$wshell.SendKeys('hero')
Start-Sleep -Milliseconds 500
TakeScreenshot "$ssDir\fc_step6_typed.png"

# Press Enter to confirm
Activate 500
$wshell.SendKeys('{ENTER}')
Start-Sleep -Seconds 8
TakeScreenshot "$ssDir\fc_step7_created.png"
Write-Host "Step 7: Character creation result screenshot taken"

# Step 8: If character was created, it should be in the list.
# Press Enter to select the character and enter the game world.
Write-Host "Step 8: Selecting character to enter game..."
Activate 500
$wshell.SendKeys('{ENTER}')
Start-Sleep -Seconds 10
TakeScreenshot "$ssDir\fc_step8_loading.png"

# Wait more for 3D world to load
Start-Sleep -Seconds 10
TakeScreenshot "$ssDir\fc_step9_gameworld.png"
Write-Host "Step 9: Game world screenshot taken"

Start-Sleep -Seconds 5
TakeScreenshot "$ssDir\fc_step10_final.png"
Write-Host "Done. All screenshots taken."
