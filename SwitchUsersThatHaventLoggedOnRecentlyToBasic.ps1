(param([Parameter(Mandatory=$true,Position=1)]
[string]$API_Key))

# To be used only during debug
$DEBUG_maxNoPages = 3000

$OAuthToken = "TOBECOMPUTED"
$zoomUsersEndpoint = "https://api.zoom.us/v2/users"

# The number of the page is 1-based
$pageNumber = 1

# Initialize the number of pages. This will be overwritten when reading the first page
$noOfPages = 0

# We'll also use the maximum allowed number of entries per page
$MAX_NO_ENTRIES_PER_PAGE = 300

# The number of months over which we consider the users that haven't logged on as inactive
$MAX_NO_MONTHS_AS_INACTIVE = 5

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
    $global:response = Invoke-RestMethod @params

    # Error handling should be HERE

    # If this is the first request, then obtain how many pages there are
    if($pageNumber -eq 1) {
        $noOfPages = $response.page_count
        Write-Host "$noOfPages pages of results, containing $($response.total_records) entries"
        Write-Host "Reading the first $DEBUG_maxNoPages or $noOfPages, whichever comes first"
    }

    # Add the current batch of users returned in the current page to our array
    $global:users += $response.users
    
    # Enter a delay so we don't hit the rate limits https://marketplace.zoom.us/docs/api-reference/rate-limits#rate-limits
    Start-Sleep -Milliseconds 100
    Write-Host -NoNewline "."

    $pageNumber++
} while ($pageNumber -le $noOfPages -and $pageNumber -le $DEBUG_maxNoPages)

Write-Host

# Copy all the columns to another object, but convert to DateTime the ones that store
#  time info as they're currently plain strings
$global:parsedUsers = $users | Select-Object id, first_name, last_name, email, type, pmi, timezone, verified,
    @{label="createdAt";expression={$_.createdAt.ToDateTime([CultureInfo]::new("en-us"))}},
    @{label="lastLoginTime";expression={$_.last_login_time.ToDateTime([CultureInfo]::new("en-us"))}},
    last_client_version, language, phone_number, status


 # Set the cutover date over which we consider users as inactive   
$cutoffDate = (Get-Date).AddMonths(-$MAX_NO_MONTHS_AS_INACTIVE)
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
    $global:response = Invoke-RestMethod @params

    # Enter a delay so we don't hit the rate limits https://marketplace.zoom.us/docs/api-reference/rate-limits#rate-limits
    Start-Sleep -Milliseconds 100
    Write-Host -NoNewline "."
}
