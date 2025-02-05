# Helpers
function Connect-Sps
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$SessionMaster,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$SessionUsername,
        [Parameter(Mandatory=$true,Position=2)]
        [SecureString]$SessionPassword,
        [Parameter(Mandatory=$false)]
        [switch]$Insecure
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    Import-Module -Name "$PSScriptRoot\sslhandling.psm1" -Scope Local
    Edit-SslVersionSupport
    if ($Insecure)
    {
        Disable-SslVerification
        if ($global:PSDefaultParameterValues) { $PSDefaultParameterValues = $global:PSDefaultParameterValues.Clone() }
    }

    $local:PasswordPlainText = [System.Net.NetworkCredential]::new("", $SessionPassword).Password

    try
    {
        $local:BasicAuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $SessionUsername, $local:PasswordPlainText)))
        Remove-Variable -Scope local PasswordPlainText
        Invoke-RestMethod -Uri "https://$SessionMaster/api/authentication" -SessionVariable HttpSession `
            -Headers @{ Authorization = ("Basic {0}" -f $local:BasicAuthInfo) } | Write-Verbose
    }
    catch
    {
        Import-Module -Name "$PSScriptRoot\sg-utilities.psm1" -Scope Local
        Out-SafeguardExceptionIfPossible $_
    }
    finally
    {
        Remove-Variable -Scope local BasicAuthInfo
    }

    $HttpSession
}
function New-SpsUrl
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$RelativeUrl,
        [Parameter(Mandatory=$false)]
        [object]$Parameters
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    $local:Url = "https://$($SafeguardSpsSession.Appliance)/api/$RelativeUrl"
    if ($Parameters -and $Parameters.Length -gt 0)
    {
        $local:Url += "?"
        $Parameters.Keys | ForEach-Object {
            $local:Url += ($_ + "=" + [uri]::EscapeDataString($Parameters.Item($_)) + "&")
        }
        $local:Url = $local:Url -replace ".$"
    }
    $local:Url
}
function Invoke-SpsWithBody
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Method,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$RelativeUrl,
        [Parameter(Mandatory=$true,Position=2)]
        [object]$Headers,
        [Parameter(Mandatory=$false)]
        [object]$Body,
        [Parameter(Mandatory=$false)]
        [object]$JsonBody,
        [Parameter(Mandatory=$false)]
        [object]$Parameters
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    $local:BodyInternal = $JsonBody
    if ($Body)
    {
        $local:BodyInternal = (ConvertTo-Json -Depth 100 -InputObject $Body)
    }
    $local:Url = (New-SpsUrl $RelativeUrl -Parameters $Parameters)
    Write-Verbose "Url=$($local:Url)"
    Write-Verbose "Parameters=$(ConvertTo-Json -InputObject $Parameters)"
    Write-Verbose "---Request Body---"
    Write-Verbose "$($local:BodyInternal)"
    Invoke-RestMethod -WebSession $SafeguardSpsSession.Session -Method $Method -Headers $Headers -Uri $local:Url `
                      -Body ([System.Text.Encoding]::UTF8.GetBytes($local:BodyInternal)) `
}
function Invoke-SpsWithoutBody
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Method,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$RelativeUrl,
        [Parameter(Mandatory=$true,Position=2)]
        [object]$Headers,
        [Parameter(Mandatory=$false)]
        [object]$Parameters
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    $local:Url = (New-SpsUrl $RelativeUrl -Parameters $Parameters)
    Write-Verbose "Url=$($local:Url)"
    Write-Verbose "Parameters=$(ConvertTo-Json -InputObject $Parameters)"
    Invoke-RestMethod -WebSession $SafeguardSpsSession.Session -Method $Method -Headers $Headers -Uri $local:Url
}
function Invoke-SpsInternal
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Method,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$RelativeUrl,
        [Parameter(Mandatory=$true,Position=2)]
        [object]$Headers,
        [Parameter(Mandatory=$false)]
        [object]$Body,
        [Parameter(Mandatory=$false)]
        [string]$JsonBody,
        [Parameter(Mandatory=$false)]
        [HashTable]$Parameters
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    try
    {
        switch ($Method.ToLower())
        {
            {$_ -in "get","delete"} {
                Invoke-SpsWithoutBody $Method $RelativeUrl $Headers -Parameters $Parameters
                break
            }
            {$_ -in "put","post"} {
                Invoke-SpsWithBody $Method $RelativeUrl $Headers `
                    -Body $Body -JsonBody $JsonBody -Parameters $Parameters
                break
            }
        }
    }
    catch
    {
        Import-Module -Name "$PSScriptRoot\sg-utilities.psm1" -Scope Local
        Out-SafeguardExceptionIfPossible $_
    }
}


<#
.SYNOPSIS
Log into a Safeguard SPS appliance in this Powershell session for the purposes
of using the SPS Web API.

.DESCRIPTION
This utility can help you securely create a login session with a Safeguard SPS
appliance and save it as a global variable.

The password may be passed in as a SecureString.  By default, this
script will securely prompt for the password.

.PARAMETER Appliance
IP address or hostname of a Safeguard SPS appliance.

.PARAMETER Insecure
Ignore verification of Safeguard SPS appliance SSL certificate--will be ignored for entire session.

.PARAMETER Username
The username to authenticate as.

.PARAMETER Password
SecureString containing the password.

.INPUTS
None.

.OUTPUTS
None (with session variable filled out for calling Sps Web API).


.EXAMPLE
Connect-SafeguardSps 10.5.32.54 admin -Insecure

Login Successful.

.EXAMPLE
Connect-SafeguardSps sps1.mycompany.corp admin

Login Successful.
#>
function Connect-SafeguardSps
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Appliance,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$Username,
        [Parameter(Mandatory=$false)]
        [SecureString]$Password,
        [Parameter(Mandatory=$false)]
        [switch]$Insecure
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    if (-not $Password)
    {
        $Password = (Read-Host "Password" -AsSecureString)
    }

    $local:HttpSession = (Connect-Sps -SessionMaster $Appliance -SessionUsername $Username -SessionPassword $Password -Insecure:$Insecure)
    Set-Variable -Name "SafeguardSpsSession" -Scope Global -Value @{
        "Appliance" = $Appliance;
        "Insecure" = $Insecure;
        "Session" = $local:HttpSession
    }
    Write-Host "Login Successful."
}

<#
.SYNOPSIS
Log out of a Safeguard SPS appliance when finished using the SPS Web API.

.DESCRIPTION
This utility will remove the session variable
that was created by the Connect-SafeguardSps cmdlet.

.INPUTS
None.

.OUTPUTS
None.

.EXAMPLE
Disconnect-SafeguardSps

Log out Successful.

#>
function Disconnect-SafeguardSps
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    if (-not $SafeguardSpsSession)
    {
        Write-Host "Not logged in."
    }
    else
    {
        Write-Host "Session variable removed."
        Set-Variable -Name "SafeguardSpsSession" -Scope Global -Value $null
    }
}

<#
.SYNOPSIS
Call a method in the Safeguard SPS Web API.

.DESCRIPTION
This utility is useful for calling the Safeguard SPS Web API for testing or
scripting purposes. It provides a couple benefits over using curl.exe or
Invoke-RestMethod by generating or reusing a secure session and composing
the Url, headers, parameters, and body for the request.

This script is meant to be used with the Connect-SafeguardSps cmdlet which
will generate and store a variable in the session so that it doesn't need
to be passed to each call to the API.  Call Disconnect-SafeguardSps when
finished.

Safeguard SPS Web API is implemented as HATEOAS. To get started crawling
through the API, call Show-SafeguardSpsEndpoint.  Then, you can follow to
the different API areas, such as configuration or health-status.

.PARAMETER Appliance
IP address or hostname of a Safeguard appliance.

.PARAMETER Method
HTTP method verb you would like to use: GET, PUT, POST, DELETE.

.PARAMETER RelativeUrl
Relative portion of the Url you would like to call starting after /api.

.PARAMETER Accept
Specify the Accept header (default: application/json), Use text/csv to request CSV output.

.PARAMETER ContentType
Specify the Content-type header (default: application/json).

.PARAMETER Body
A hash table containing an object to PUT or POST to the Url.

.PARAMETER JsonBody
A pre-formatted JSON string to PUT or Post to the URl.  If -Body is also specified, this is ignored.
It can sometimes be difficult to get arrays of objects to behave properly with hashtables in Powershell.

.PARAMETER Parameters
A hash table containing the HTTP query parameters to add to the Url.

.PARAMETER JsonOutput
A switch to return data as pretty JSON string.

.PARAMETER BodyOutput
A switch to just return the body as a PowerShell object.

.INPUTS
None.

.OUTPUTS
JSON response from Safeguard Web API.

.EXAMPLE
Invoke-SafeguardSpsMethod GET starling/join

.EXAMPLE
Invoke-SafeguardSpsMethod GET / -JsonOutput

.EXAMPLE
Open-SafeguardSpsTransaction
$body = (Invoke-SafeguardSpsMethod GET configuration/management/email -BodyOutput)
$body.admin_address = "admin@mycompany.corp"
Invoke-SafeguardSpsMethod PUT configuration/management/email -Body $body
Close-SafeguardSpsTransaction
#>
function Invoke-SafeguardSpsMethod
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Method,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$RelativeUrl,
        [Parameter(Mandatory=$false)]
        [string]$Accept = "application/json",
        [Parameter(Mandatory=$false)]
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$false)]
        [object]$Body,
        [Parameter(Mandatory=$false)]
        [string]$JsonBody,
        [Parameter(Mandatory=$false)]
        [HashTable]$Parameters,
        [Parameter(Mandatory=$false)]
        [HashTable]$ExtraHeaders,
        [Parameter(Mandatory=$false)]
        [switch]$JsonOutput,
        [Parameter(Mandatory=$false)]
        [switch]$BodyOutput
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    if (-not $SafeguardSpsSession)
    {
        throw "This cmdlet requires that you log in with the Connect-SafeguardSps cmdlet"
    }

    $local:Insecure = $SafeguardSpsSession.Insecure
    Write-Verbose "Insecure=$($local:Insecure)"
    Import-Module -Name "$PSScriptRoot\sslhandling.psm1" -Scope Local
    Edit-SslVersionSupport
    if ($local:Insecure)
    {
        Disable-SslVerification
        if ($global:PSDefaultParameterValues) { $PSDefaultParameterValues = $global:PSDefaultParameterValues.Clone() }
    }

    $local:Headers = @{
        "Accept" = $Accept;
        "Content-type" = $ContentType;
    }

    foreach ($key in $ExtraHeaders.Keys)
    {
        $local:Headers[$key] = $ExtraHeaders[$key]
    }

    Write-Verbose "---Request---"
    Write-Verbose "Headers=$(ConvertTo-Json -InputObject $local:Headers)"

    try
    {
        if ($JsonOutput)
        {
            (Invoke-SpsInternal $Method $RelativeUrl $local:Headers `
                                -Body $Body -JsonBody $JsonBody -Parameters $Parameters) | ConvertTo-Json -Depth 100
        }
        elseif ($BodyOutput)
        {
            $local:Response = (Invoke-SpsInternal $Method $RelativeUrl $local:Headers -Body $Body -JsonBody $JsonBody -Parameters $Parameters)
            if ($local:Response.body)
            {
                $local:Response.body
            }
            else
            {
                Write-Verbose "No body returned in response"
            }
        }
        else
        {
            Invoke-SpsInternal $Method $RelativeUrl $local:Headers -Body $Body -JsonBody $JsonBody -Parameters $Parameters
        }
    }
    finally
    {
        if ($local:Insecure)
        {
            Enable-SslVerification
            if ($global:PSDefaultParameterValues) { $PSDefaultParameterValues = $global:PSDefaultParameterValues.Clone() }
        }
    }
}

<#
.SYNOPSIS
Open a transaction for making changes via the Safeguard SPS Web API.

.DESCRIPTION
This cmdlet is used to create a transaction necessary to make changes via
the Safeguard SPS API.  Recent versions of SPS will open a transaction
automatically, but this cmdlet may be used to open a transaction explicitly.

In order to permanently save changes made via the Safeguard SPS API, you
must also call Close-SafeguardSpsTransaction or its alias
Save-SafeguardSpsTransaction.  Clear-SafeguardSpsTransaction can be used to
cancel changes.

.INPUTS
None.

.OUTPUTS
JSON response from Safeguard Web API.

.EXAMPLE
Open-SafeguardSpsTransaction
$body = (Invoke-SafeguardSpsMethod GET configuration/management/email -BodyOutput)
$body.admin_address = "admin@mycompany.corp"
Invoke-SafeguardSpsMethod PUT configuration/management/email -Body $body
Close-SafeguardSpsTransaction
#>
function Open-SafeguardSpsTransaction
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    Invoke-SafeguardSpsMethod POST transaction
}

<#
.SYNOPSIS
Close a transaction and save changes made via the Safeguard SPS Web API.

.DESCRIPTION
This cmdlet is used to end a transaction and permanently save the changes
made via the Safeguard SPS API.  This cmdlet is meant to be used with
Open-SafeguardSpsTransaction.  Save-SafeguardSpsTransaction is an alias
for this cmdlet.  Clear-SafeguardSpsTransaction can be used to cancel changes.

To see the status of a transaction, use Get-SafeguardSpsTransaction.  To
see only the changes that are about to be made via a transaction, use
Show-SafeguardSpsTransactionChange.

.INPUTS
None.

.OUTPUTS
JSON response from Safeguard Web API.

.EXAMPLE
Open-SafeguardSpsTransaction
$body = (Invoke-SafeguardSpsMethod GET configuration/management/email -BodyOutput)
$body.admin_address = "admin@mycompany.corp"
Invoke-SafeguardSpsMethod PUT configuration/management/email -Body $body
Close-SafeguardSpsTransaction
#>
function Close-SafeguardSpsTransaction
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    Invoke-SafeguardSpsMethod PUT transaction -Body @{ status = "commit" }
}
New-Alias -Name Save-SafeguardSpsTransaction -Value Close-SafeguardSpsTransaction

<#
.SYNOPSIS
Get the status of a transaction using the Safeguard SPS Web API.

.DESCRIPTION
This cmdlet will report the status of an SPS transaction.  The status 'closed'
means no transaction is pending.  The status 'open' means the transaction is
pending.  Close-SafeguardSpsTransaction can be used to permanently save changes.
Clear-SafeguardSpsTransaction can be used to cancel changes.  The remaining
seconds is the time before the transaction will cancel automatically and the
login session will be terminated.

.INPUTS
None.

.OUTPUTS
JSON response from Safeguard Web API.

.EXAMPLE
Open-SafeguardSpsTransaction
$body = (Invoke-SafeguardSpsMethod GET configuration/management/email -BodyOutput)
$body.admin_address = "admin@mycompany.corp"
Invoke-SafeguardSpsMethod PUT configuration/management/email -Body $body
Get-SafeguardSpsTransaction
Clear-SafeguardSpsTransaction
#>
function Get-SafeguardSpsTransaction
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    $local:response = (Invoke-SafeguardSpsMethod GET transaction)
    $local:TransactionInfo = [ordered]@{
        Status = $local:response.body.status;
        CommitMessage = $local:response.body.commit_message;
        RemainingSeconds = $local:response.meta.remaining_seconds;
        Changes = @()
    }
    if ($local:response.meta.changes)
    {
        $local:Changes = (Invoke-SafeguardSpsMethod GET transaction/changes).changes
        if ($local:Changes) { $local:TransactionInfo.Changes = $local:Changes }
    }
    New-Object PSObject -Property $local:TransactionInfo
}

<#
.SYNOPSIS
Show the pending changes in a transaction using the Safeguard SPS Web API.

.DESCRIPTION
Transactions are required to make changes via the Safeguard SPS Web API.  The
transaction must be closed or saved before changes become permanent.  This cmdlet
will show what values will be permanently changed if the transaction is closed.

.INPUTS
None.

.OUTPUTS
JSON response from Safeguard Web API.

.EXAMPLE
Open-SafeguardSpsTransaction
$body = (Invoke-SafeguardSpsMethod GET configuration/management/email -BodyOutput)
$body.admin_address = "admin@mycompany.corp"
Invoke-SafeguardSpsMethod PUT configuration/management/email -Body $body
Show-SafeguardSpsTransactionChange
#>
function Show-SafeguardSpsTransactionChange
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    (Get-SafeguardSpsTransaction).Changes | ConvertTo-Json -Depth 100
}

<#
.SYNOPSIS
Cancel a transaction using the Safeguard SPS Web API.

.DESCRIPTION
Transactions are required to make changes via the Safeguard SPS Web API.  The
transaction must be closed or saved before changes become permanent.  This cmdlet
may be used to cancel pending changes.

.INPUTS
None.

.OUTPUTS
JSON response from Safeguard Web API.

.EXAMPLE
Open-SafeguardSpsTransaction
$body = (Invoke-SafeguardSpsMethod GET configuration/management/email -BodyOutput)
$body.admin_address = "admin@mycompany.corp"
Invoke-SafeguardSpsMethod PUT configuration/management/email -Body $body
Get-SafeguardSpsTransaction
Clear-SafeguardSpsTransaction
#>
function Clear-SafeguardSpsTransaction
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    Invoke-SafeguardSpsMethod DELETE transaction
}

<#
.SYNOPSIS
Call a method in the Safeguard SPS Web API.

.DESCRIPTION
Safeguard SPS Web API is implemented as HATEOAS. This cmdlet is helpful for
crawling through the API.  You can explore the different API areas, such as
configuration or health-status.

.PARAMETER RelativeUrl
Relative portion of the Url you would like to call starting after /api.

.EXAMPLE
Show-SafeguardSpsEndpoint configuration

.EXAMPLE
Show-SafeguardSpsEndpoint configuration/ssh/connections
#>
function Show-SafeguardSpsEndpoint
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false,Position=0)]
        [string]$RelativeUrl
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    if (-not $RelativeUrl) { $RelativeUrl = "/" }

    $local:Response = (Invoke-SafeguardSpsMethod GET $RelativeUrl)
    if ($local:Response.items)
    {
        $local:Response.items | Select-Object key,meta
    }
    else
    {
        $local:Response.meta.href
    }
}

<#
.SYNOPSIS
Gather join information from Safeguard SPS and open a browser to Starling to
complete the join via the Safeguard SPS Web API.

.DESCRIPTION
This cmdlet with call the Safeguard SPS API to determine the join status, and
if not joined, it will gather the information necessary to start the join
process using the system browser. The join process requires copying and pasting
credentials and token endpoint back from the browser to complete the join.
Credentials will not be echoed to the screen.

.PARAMETER Environment
Which Starling environment to join (default: prod)

.EXAMPLE
Invoke-SafeguardSpsStarlingJoinBrowser
#>
function Invoke-SafeguardSpsStarlingJoinBrowser
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false,Position=0)]
        [ValidateSet("dev", "devtest", "stage", "prod", IgnoreCase=$true)]
        [string]$Environment = "prod"
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    $local:Info = (Invoke-SafeguardSpsMethod GET configuration/starling).body
    if ($local:Info.join_info)
    {
        Write-Host -ForegroundColor Yellow "Safeguard SPS is already joined to Starling"
        $local:Info.join_info
        Write-Host -ForegroundColor Yellow "You must unjoin before you can rejoin Starling"
    }
    else
    {
        $local:JoinBody = (Invoke-SafeguardSpsMethod GET starling/join).body
        $local:InstanceName = $local:JoinBody.product_instance
        $local:TimsLicense = $local:JoinBody.product_tims
        switch ($Environment)
        {
            "dev" { $local:Suffix = "-dev"; $Environment = "dev"; break }
            "devtest" { $local:Suffix = "-devtest"; $Environment = "devtest"; break }
            "stage" { $local:Suffix = "-stage"; $Environment = "stage"; break }
            "prod" { $local:Suffix = ""; $Environment = "prod"; break }
        }
        $local:JoinUrl = "https://account$($local:Suffix).cloud.oneidentity.com/join/Safeguard/$($local:InstanceName)/$($local:TimsLicense)"

        Import-Module -Name "$PSScriptRoot\ps-utilities.psm1" -Scope Local

        Write-Host -ForegroundColor Yellow "This command will use an external browser to join Safeguard SPS ($($local:InstanceName)) to Starling ($Environment)."
        Write-host "You will be required to copy and paste interactively from the browser to answer prompts for join information."
        $local:Confirmed = (Get-Confirmation "Join to Starling" "Are you sure you want to use an external browser to join to Starling?" `
                                            "Show the browser." "Cancels this operation.")

        if ($local:Confirmed)
        {
            Start-Process $local:JoinUrl

            Write-Host "Following the successful join in the browser, provide the following:"
            $local:Creds = (Read-Host "Credential String" -MaskInput)
            $local:Endpoint = (Read-Host "Token Endpoint")
            $local:Body = [ordered]@{
                environment = $Environment;
                token_endpoint = $local:Endpoint;
                credential_string = $local:Creds;
            }
            $local:JoinBody | Add-Member -NotePropertyMembers $local:Body -TypeName PSCustomObject

            Invoke-SafeguardSpsMethod POST "starling/join" -Body $local:JoinBody

            Write-Host -ForegroundColor Yellow "You may close the external browser."
        }
    }
}

<#
.SYNOPSIS
Remove the Starling join via the Safeguard SPS Web API.

.DESCRIPTION
This cmdlet with call the Safeguard SPS API to remove a Starling join. You
cannot unjoin if SRA is enabled.

.EXAMPLE
Remove-SafeguardSpsStarlingJoin
#>
function Remove-SafeguardSpsStarlingJoin
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    Invoke-SafeguardSpsMethod DELETE starling/join
}

<#
.SYNOPSIS
Enable Safeguard Remote Access in Starling via the Safeguard SPS Web API.

.DESCRIPTION
This cmdlet will enable Safeguard Remote Access in Starling if this Safeguard SPS
is joined to Starling.

.EXAMPLE
Enable-SafeguardSpsStarlingJoin
#>
function Enable-SafeguardSpsRemoteAccess
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    $local:Info = (Invoke-SafeguardSpsMethod GET configuration/starling).Body
    if ($local:Info.remote_access.enabled)
    {
        Write-Warning "Safeguard Remote Access is already enabled"
    }
    else
    {
        $local:Info.remote_access.enabled = $true
        Open-SafeguardSpsTransaction
        Invoke-SafeguardSpsMethod PUT configuration/starling -Body $local:Info
        Save-SafeguardSpsTransaction
    }
}
New-Alias -Name Enable-SafeguardSpsSra -Value Enable-SafeguardSpsRemoteAccess

<#
.SYNOPSIS
Disable Safeguard Remote Access in Starling via the Safeguard SPS Web API.

.DESCRIPTION
This cmdlet will disable Safeguard Remote Access in Starling if this Safeguard SPS
is joined to Starling.

.EXAMPLE
Disable-SafeguardSpsStarlingJoin
#>
function Disable-SafeguardSpsRemoteAccess
{
    [CmdletBinding()]
    Param(
    )

    if (-not $PSBoundParameters.ContainsKey("ErrorAction")) { $ErrorActionPreference = "Stop" }
    if (-not $PSBoundParameters.ContainsKey("Verbose")) { $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference") }

    $local:Info = (Invoke-SafeguardSpsMethod GET configuration/starling).Body
    if ($local:Info.remote_access.enabled)
    {
        $local:Info.remote_access.enabled = $false
        Open-SafeguardSpsTransaction
        Invoke-SafeguardSpsMethod PUT configuration/starling -Body $local:Info
        Save-SafeguardSpsTransaction
    }
    else
    {
        Write-Warning "Safeguard Remote Access is already disabled"
    }
}
New-Alias -Name Disable-SafeguardSpsSra -Value Disable-SafeguardSpsRemoteAccess
