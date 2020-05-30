# CONSTANTS
$API_KEY = 'TOBEPASSEDASPARAM'
$API_Secret = 'TOBEPASSEDASPARAM'

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


do {
    try {    
        $JWT_token = BuildZoomJWTtoken -API_KEY $API_KEY -API_Secret $API_Secret -validForSeconds 300
        $params = @{
                    Method = 'GET'
                    URI = 'https://api.zoom.us/v2/users/me'
                    Headers = @{ Authorization = "Bearer $JWT_token" }
        }
        Write-Host "Using token: $JWT_token"
        $global:response = Invoke-RestMethod @params
    }
    catch{
        Write-Host "Rest call threw exception: ($_.Exception)"
        $global:exc = $_
        exit
    }
    Start-Sleep -Milliseconds 50
} while($true)