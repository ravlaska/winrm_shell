# ============================================================ ENCRYPTION ============================================================
# Generating key
function Derive-Key {
    param (
        [SecureString]$Password,
        [byte[]]$Salt,
        [int]$KeySize = 32,
        [int]$Iterations = 10000
    )
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $passwordPlainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    
    $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($passwordPlainText, $Salt, $Iterations)
    return $deriveBytes.GetBytes($KeySize)
}

# Generating salt
function Generate-Salt {
    param (
        [int]$Size = 16
    )
    $salt = New-Object byte[] $Size
    [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($salt)
    return $salt
}

# Encrypting string and save to base file
function Encrypt-String {
    param (
        [string]$PlainText,
        [SecureString]$Password
    )
    try {
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $salt = Generate-Salt
        $aes.Key = Derive-Key -Password $Password -Salt $salt
        $aes.GenerateIV()
        $iv = $aes.IV

        $encryptor = $aes.CreateEncryptor($aes.Key, $aes.IV)
        $plainTextBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)

        $encryptedBytes = $encryptor.TransformFinalBlock($plainTextBytes, 0, $plainTextBytes.Length)
        $encryptor.Dispose()

        $combinedData = $salt + $iv + $encryptedBytes
        $encryptedString = [Convert]::ToBase64String($combinedData)
        
        # Writing the encrypted data to a file
        [System.IO.File]::WriteAllBytes($FilePath, $combinedData)
        
    } catch {
        Write-Host "${red}`nAn error occurred during encryption: $_${reset}"
        exit 1
    }
}

# Decrypting string from base file
function Decrypt-StringFromFile {
    param (
        [SecureString]$Password
    )

    try {
        # Reading the encrypted data from the file
        $combinedData = [System.IO.File]::ReadAllBytes($FilePath)
        $salt = $combinedData[0..15]
        $iv = $combinedData[16..31]
        $encryptedBytes = $combinedData[32..($combinedData.Length - 1)]

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.Key = Derive-Key -Password $Password -Salt $salt
        $aes.IV = $iv

        $decryptor = $aes.CreateDecryptor($aes.Key, $aes.IV)
        $decryptedBytes = $decryptor.TransformFinalBlock($encryptedBytes, 0, $encryptedBytes.Length)
        $decryptor.Dispose()

        $decryptedString = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        
        return $decryptedString
    } 
    catch {
        return $false
    }
}

# Checking if the base file exists
function Get-FilePath {
    if (Test-Path -Path $FilePath -PathType Leaf) {
        # if file exists, return the file path
        Write-Host "${green}WinRMS Base file detected!`n"
        return $true
    } else {
        # if file does not exist, return null or an appropriate message
        while (1){
            Print-Banner
            Write-Host "`n${red}WinRM Secure Base file not detected.${reset}"
            $doCreateFile = Read-Host "${dblue}Do you want to create it or enter the manual mode? (c/m)${reset}"
            # Creating base file
            if ($doCreateFile -eq "c") {
                $Password = Read-Host "`n${yellw}Set the password to database file${reset}" -AsSecureString
                $PlainText = @{
                    hosts = @()
                }
                $json = ConvertTo-Json $PlainText
                Encrypt-String -PlainText $json -Password $Password
                Write-Host "${dblue}`nBase file created.`nRun this script once again.${reset}`n"
                exit 0
            }
            # go to manual mode
            if ($doCreateFile -eq "m") {
                return $false
            }
            # wrong selection message
            else {
                Write-Host "${dred}Please select valid option.${reset}"
                Start-Sleep -Seconds 2
            }
        }
    }
}

# ============================================================ DB WORKER ============================================================
# Retrieving hosts from the base file
function List-Hosts {
    param (
        [string]$JsonHosts
    )

    while (1){

        $hosts = ConvertFrom-Json $JsonHosts
        $dnses = @()

        # Creating array with hosts from base file
        for ($i = 0; $i -lt $hosts.hosts.Count; $i++) {
            $dnses += "[{0}] - {1}" -f ($i), $hosts.hosts[$i].dns
        }

        clear
        Print-Banner
        Write-Host "${yellw}DNS addresses loaded from the base:`n${reset}"
        Write-Host "${green}[M] - Manual connection${reset}"
        Write-Host "${green}[A] - Add new host${reset}"
        Write-Host "${green}[R] - Remove host`n${reset}"
        foreach ($entry in $dnses) {
            Write-Host "$dgreen$entry$reset"
        }

        Write-Host ""
        $selection = Read-Host "${dblue}Select host to connect with${reset}"

        # Adding new host entry option
        if ($selection -match "^[aA]$") {
            $JsonHosts = Add-Host -JsonData $JsonHosts
        }
        # Entering into manual mode
        if ($selection -match "^[mM]$") {
            return $false
        }
        # Removing host menu
        if ($selection -match "^[rR]$") {
            $hostToRemove = Read-Host "${dblue}Select host to remove${reset}"
            $JsonHosts = Remove-HostEntry -EntryName $hosts.hosts[$hostToRemove].dns -JsonData $JsonHosts
        }
        # Returning selected host
        if ($selection -match '^[+-]?\d+(\.\d+)?$') {
            $selected_host = $hosts.hosts[$selection]
            break
        }
    }
    
    return $selected_host
}

# Removing host entry
function Remove-HostEntry {
    param (
        [string]$JsonData,
        [string]$EntryName
    )
    
    $hosts = ConvertFrom-Json $JsonData

    # filtering which entry we want to remove
    $hosts.hosts = $hosts.hosts | Where-Object { $_.dns -ne $EntryName }
    # repairing array if that was only entry that was removed
    if ($hosts.hosts -eq $null) {
        $hosts.hosts = @()
    }

    $JsonData = ConvertTo-Json $hosts
    Encrypt-String -PlainText $JsonData -Password $Password

    return $JsonData
}

# Adding new host entry
function Add-Host {
    param (
        [string]$JsonData
    )

    clear
    Print-Banner
    Write-Host "${yellw}Creating new host entry.`n${reset}"

    $hosts = ConvertFrom-Json $JsonData
    
    $creds = Get-Credentials
    $newEntry = @{
        dns=$creds[0]
        login=$creds[1]
        pass=$creds[2]
    }

    # Checking if entered host is already in the base file
    $existDns = ($hosts.hosts | Where-Object { $_.dns -eq $creds[0] })

    if ($existDns) {
        Write-Host "${dred}An entry with DNS '$($newEntry.dns)' already exists.${reset}"
        Start-Sleep -Seconds 2
        $JsonData = ConvertTo-Json $hosts
        return $JsonData
    }

    # Trying to create session with host
    $session = Create-Connection -Username $creds[1] -Password $creds[2] -VMDns $creds[0]

    # if session is ok
    if ($session) {
        Write-Host "`n${green}[INFO] ${yellw}WinRM is working fine. Entry successfully created.`n${reset}"
        Start-Sleep -Seconds 2
        $hosts.hosts += $newEntry
        $JsonData = ConvertTo-Json $hosts
        Encrypt-String -PlainText $JsonData -Password $Password
        return $JsonData
    }
    # if session creation went wrong
    else {
        Write-Host "`n${red}[ERROR] ${yellw}WinRM is not working. Entry not created.`n${reset}"
        Start-Sleep -Seconds 2
        $JsonData = ConvertTo-Json $hosts
        return $JsonData
    }
}

# Creating session with host
function Create-Connection {
    param (
        [string]$Username,
        [string]$Password,
        [string]$VMDns
    )
    
    Write-Host "`n${yellw}Creating session with: ${VMDns}`n${reset}"

    $SecPassword = ConvertTo-SecureString $Password -AsPlainText -Force

    # Creating credentials object
    $credentials = New-Object System.Management.Automation.PSCredential($Username, $SecPassword)

    # Defining session option
    $pso = New-PSSessionOption -SkipCACheck

    # Trying to create session
    $session = New-PSSession -ComputerName $VMDns -UseSSL -SessionOption $pso -Credential $credentials -ErrorAction SilentlyContinue

    return $session
}

# Reading credentials from user
function Get-Credentials {
    $creds_array = @()
    
    # Retrieving credentials
    Write-Host "${dblue}`nProvide credentials for WinRM connection:`n${reset}"
    $creds_array += Read-Host "${green}DNS address${reset}"
    $creds_array += Read-Host "${green}Username${reset}"
    $creds_array += Read-Host "${green}Password${reset}"

    return $creds_array
}

# Session handler
function Create-Session {
    param (
        [string]$Username,
        [string]$Password,
        [string]$VMDns
    )

    $session = Create-Connection -Username $Username -Password $Password -VMDns $VMDns

    # Printing info about session status
    if ($session) {
        Write-Host "`n${green}[INFO] ${yellw}WinRM is working fine. Session successfully created.`n${reset}"
    }
    else {
        Write-Host "`n${red}[ERROR] ${yellw}WinRM is not working. Please check VM configuration.`n${reset}"
        exit 1
    }

    # Asking about entering PS session
    $entersession = Read-Host "${dblue}Do you want to enter PS Session? (y - yes / other char - no)${reset}"

    if ($entersession -match "^[yY]$") {
        # Entering PS session
        Write-Host "`n`n${sess}Establishing session with ${VMDns}:"
        Enter-PSSession -Session $session
        break
    }
    else {
        exit 0
    }
}

# Manual mode connection option
function Manual-Mode {
    Print-Banner
    $creds = Get-Credentials
    Create-Session -Username $creds[1] -Password $creds[2] -VMDns $creds[0]
}

# Checking parent process
function Get-ParentProcess {
    $parentProcessId = (Get-WmiObject Win32_Process -Filter "ProcessId=$pid").ParentProcessId
    Get-Process -Id $parentProcessId
}

# Printing banner
function Print-Banner {
$banner = @"
${dred} █     █░ ██▓ ███▄    █  ██▀███   ███▄ ▄███▓     ██████  ██░ ██ ▓█████  ██▓     ██▓    
${dred}▓█░ █ ░█░▓██▒ ██ ▀█   █ ▓██ ▒ ██▒▓██▒▀█▀ ██▒   ▒██    ▒ ▓██░ ██▒▓█   ▀ ▓██▒    ▓██▒    
${dred}▒█░ █ ░█ ▒██▒▓██  ▀█ ██▒▓██ ░▄█ ▒▓██    ▓██░   ░ ▓██▄   ▒██▀▀██░▒███   ▒██░    ▒██░    
${dred}░█░ █ ░█ ░██░▓██▒  ▐▌██▒▒██▀▀█▄  ▒██    ▒██      ▒   ██▒░▓█ ░██ ▒▓█  ▄ ▒██░    ▒██░    
${dred}░░██▒██▓ ░██░▒██░   ▓██░░██▓ ▒██▒▒██▒   ░██▒   ▒██████▒▒░▓█▒░██▓░▒████▒░██████▒░██████▒
${dred}░ ▓░▒ ▒  ░▓  ░ ▒░   ▒ ▒ ░ ▒▓ ░▒▓░░ ▒░   ░  ░   ▒ ▒▓▒ ▒ ░ ▒ ░░▒░▒░░ ▒░ ░░ ▒░▓  ░░ ▒░▓  ░
${dred}  ▒ ░ ░   ▒ ░░ ░░   ░ ▒░  ░▒ ░ ▒░░  ░      ░   ░ ░▒  ░ ░ ▒ ░▒░ ░ ░ ░  ░░ ░ ▒  ░░ ░ ▒  ░
${dred}  ░   ░   ▒ ░   ░   ░ ░   ░░   ░ ░      ░      ░  ░  ░   ░  ░░ ░   ░     ░ ░     ░ ░   
${dred}    ░     ░           ░    ░            ░            ░   ░  ░  ░   ░  ░    ░  ░    ░  ░
"@                                                                                                                          

    # Cleaning terminal and printing banner
    clear
    Write-Host $banner
}

# ============================================================ SCRIPT ============================================================

# Defining winrms base file location and name
$FilePath = "${env:USERPROFILE}/.winrms_base"

# Defining some colors
$ansiEsc = [char]27
$reset = "$ansiEsc[0m"
$dred = "$ansiEsc[38;5;124m"
$green = "$ansiEsc[38;5;36m"
$yellw = "$ansiEsc[38;5;220m"
$blue = "$ansiEsc[38;5;39m"
$dblue = "$ansiEsc[38;5;31m"
$red = "$ansiEsc[38;5;196m"
$sess = "$ansiEsc[38;5;150m"
$dgreen = "$ansiEsc[38;5;151m"


# Checking how the script was run
$parentProcess = Get-ParentProcess
if ($parentProcess.ProcessName -eq 'explorer') {
    Write-Output "${dred}Script was run using 'Run with PowerShell'.`nPlease run it from PowerShell terminal.${reset}`n"
    Read-Host -Prompt "Press Enter to exit"
    exit 0
}

Print-Banner

while (1) {
    # Checking if encrypted file exists
    if (Get-FilePath) {
        # Asking about pass if not already in vars
        if (!$Password){
            $Password = Read-Host "${yellw}Enter the password to database file${reset}" -AsSecureString
        }
        # Decrypting hosts from the base file
        if ($decryptedHosts = (Decrypt-StringFromFile -Password $Password)) {
            Print-Banner
            $selected_host = List-Hosts -JsonHosts $decryptedHosts
            # If retrieving hosts wrong, go manual mode
            if (-not $selected_host) {
                Manual-Mode
                break
            }
            # Creating session with host from the base file
            else {
                Print-Banner
                Create-Session -Username $selected_host.login -Password $selected_host.pass -VMDns $selected_host.dns
                Read-Host
                exit 0
            }
        }
        # If password is incorrect, go manual mode
        else {
            Print-Banner
            Write-Host "${red}`nIncorrect password. Continuing manually.${reset}"
            Start-Sleep -Seconds 2
            Manual-Mode
            break
        }
    }
    # If something wrong, go manual mode
    else {
        Manual-Mode
        break
    }
}

exit 0