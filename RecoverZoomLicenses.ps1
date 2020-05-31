<#
.SYNOPSIS
Converts Zoom users that are "Licensed" but haven't logged in during the 
last <n> months to "Basic", thus freeing licenses
.PARAMETER API_Key
The API_Key that must be used to connect to the Zoom API, obtained from
the JWT App's "App Credentials" tab
.PARAMETER API_Secret
The API_Secret that must be used to connect to the Zoom API, obtained from
the JWT App's "App Credentials" tab
.PARAMETER NoOfMonthsForInactivity
The number of months a user that hasn't logged in is deemed as inactive, and
eligible to have its Zoom license removed
.EXAMPLE
.\RecoverZoomLicenses.ps1 -API_Key <key> -API_Secret <secret> -months 3
Switch all the Zoom users that haven't logged in the last 3 months from "Licensed" to "Basic"
#>
Param (
    [Parameter(Mandatory=$true)]
    [string]$API_Key,
    [Parameter(Mandatory=$true)]
    [string]$API_Secret,
    [Alias('months')]
    [int]$NoOfMonthsForInactivity = 3
)


function BuildZoomJWTtoken([string]$API_KEY,
    [string]$API_Secret,
    [int]$validForSeconds) {
        ## HEADER
        # The header part stays the same: { "alg": "HS256", "typ": "JWT" }
        $headerBase64 = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'

        ## PAYLOAD
        # Token expires: now + validForSeconds
        $Expires=([DateTimeOffset]::Now.ToUnixTimeSeconds()) + $validForSeconds
        $payload = "{`"iss`":`"$API_KEY`",`"exp`":$Expires}"
        $payloadAsBytesArray = [Text.Encoding]::ASCII.GetBytes($payload)
        $payloadBase64 = [Convert]::ToBase64String($payloadAsBytesArray)
        $payloadBase64Url = $payloadBase64.Replace('=','').Replace('+','-').Replace('/','_')

        ## SIGNATURE
        $SignatureString = $headerBase64 + "." + $payloadBase64Url
        $HMAC = New-Object System.Security.Cryptography.HMACSHA256
        $HMAC.key = [Text.Encoding]::ASCII.GetBytes($API_Secret)
        $SignatureAsBytesArray = $HMAC.ComputeHash([Text.Encoding]::ASCII.GetBytes($SignatureString))
        $SignatureBase64 = [Convert]::ToBase64String($SignatureAsBytesArray)
        # Convert to base64url (https://tools.ietf.org/html/rfc4648#section-5)
        #  There are 3 rules:
        #    1. Remove the padding (=)
        #    2. Convert (+) to (-) [the 62nd char]
        #    3. Convert (/) to (_) [the 63rd char]
        #  We'll use String.Replace to avoid having (+) treated as regex by -split
        $SignatureBase64Url = $SignatureBase64.Replace('=','').Replace('+','-').Replace('/','_')
        $JWT_token = $headerBase64 + '.' + $payloadBase64Url + '.' + $SignatureBase64Url
        $JWT_token
}


$OAuthToken = BuildZoomJWTtoken -API_Key $API_Key -API_Secret $API_Secret -validForSeconds 1200
$zoomUsersEndpoint = "https://api.zoom.us/v2/users"

# The number of the page is 1-based
$pageNumber = 1

# Initialize the number of pages. This will be overwritten when reading the first page
$noOfPages = 0

# We'll also use the maximum allowed number of entries per page
$MAX_NO_ENTRIES_PER_PAGE = 300

# This will hold the list of all the users returned
$global:users = @()

do {
    # Send the first REST call request without any paging parameter
    # By default, only 'active' users are retrieved, as per https://marketplace.zoom.us/docs/api-reference/zoom-api/users/users
    $params = @{
                Method = 'GET'
                URI = $zoomUsersEndpoint
                Headers = @{ Authorization = "Bearer $OAuthToken" }
                Body = @{ page_number = $pageNumber
                          page_size = $MAX_NO_ENTRIES_PER_PAGE } 
    }
    try {
        $global:response = Invoke-RestMethod @params
    }
    catch {
        Write-Host "REST call threw exception: ($_.Exception)"
        $global:exc = $_
        exit
    }

    # If this is the first request, then obtain how many pages there are overall
    if($pageNumber -eq 1) {
        $noOfPages = $response.page_count
        Write-Host "$noOfPages pages of results, containing $($response.total_records) entries"
    }

    # Add the current batch of users returned in the current page to our array
    $global:users += $response.users
    
    # Enter a delay so we don't hit the rate limits https://marketplace.zoom.us/docs/api-reference/rate-limits#rate-limits
    Start-Sleep -Milliseconds 50
    Write-Host -NoNewline "."

    $pageNumber++
} while ($pageNumber -le $noOfPages)

Write-Host

# Copy all the columns to another object, but convert to DateTime the ones that store
#  time info as they're currently plain strings
$global:parsedUsers = $users | Select-Object id, first_name, last_name, email, type, pmi, timezone, verified,
    @{label="createdAt";expression={$_.createdAt.ToDateTime([CultureInfo]::new("en-us"))}},
    @{label="lastLoginTime";expression={$_.last_login_time.ToDateTime([CultureInfo]::new("en-us"))}},
    last_client_version, language, phone_number, status


 # Set the cutover date over which we consider users as inactive   
$cutoffDate = (Get-Date).AddMonths(-$NoOfMonthsForInactivity)
# Get the users that are licensed and haven't logged in the chosen window
$global:usersToHaveTheLicenseRemoved = $parsedUsers | ? { $_.type -eq 2 -and $_.lastLoginTime -lt $cutoffDate }

Write-Host "$(($global:usersToHaveTheLicenseRemoved | Measure-Object).count) users to be converted away from `"Licensed`""
Write-Host "Type 'yes' to continue converting these users from `"Licensed`" to `"Basic`""
$confirmText = Read-Host

if($confirmText -ne "yes") {
    exit
}

# For all the eligible users to be converted, send the REST request
#  to convert the user from "Licensed" to "Basic"
$global:usersToHaveTheLicenseRemoved | % {
    $currentUserId = $_.id
    $params = @{
        Method = 'PATCH'
        URI = "$zoomUsersEndpoint/$currentUserId"
        Headers = @{ Authorization = "Bearer $OAuthToken"
                     'Content-Type' = 'application/json' }
        Body = "{ `"type`": `"1`"}"
    }
    try {
        $global:response = Invoke-RestMethod @params
    }
    catch {
        Write-Host "REST call threw exception: ($_.Exception)"
        $global:exc = $_
        exit
    }

    # Enter a delay so we don't hit the rate limits https://marketplace.zoom.us/docs/api-reference/rate-limits#rate-limits
    Start-Sleep -Milliseconds 50
    Write-Host -NoNewline "."
}
