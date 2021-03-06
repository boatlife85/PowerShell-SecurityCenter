if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
}

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls12

if (Test-Path variable:SecurityCenter) {
    Remove-Variable SecurityCenter
}

New-Variable -Name SecurityCenter `
             -Value ( New-Object psobject -Property @{ Uri = "";
                                                       Session = $null;
                                                       RequestId = 0;
                                                       Token = $null;
                                                       User = $null; } ) `
             -Scope Global

$SecurityCenter | Add-Member -MemberType ScriptMethod -Name SystemInit -Value {
    param ([string]$SystemCenterUri,
           [System.Security.Cryptography.X509Certificates.X509Certificate]$Certificate, 
           [string]$Proxy)
    
    $Body = "module=system&action=init"

    try {
        if ($Proxy.Length -eq 0) {
            $SystemInit = Invoke-RestMethod -Uri $SystemCenterUri -Method Post -Certificate $Certificate -UseDefaultCredentials -Body $Body -SessionVariable WebSession
        } else {
            $SystemInit = Invoke-RestMethod -Uri $SystemCenterUri -Method Post -Certificate $Certificate -UseDefaultCredentials -Body $Body -SessionVariable WebSession -Proxy $Proxy -ProxyUseDefaultCredentials
        }
    } catch {
        Write-Debug "Flushdns"
        Invoke-Command -ScriptBlock { ipconfig.exe /flushdns }
        Write-Debug "Purges and reloads the remote cache name table"
        Invoke-Command -scriptblock { nbtstat.exe -R }
        Write-Debug "Kerberos list purge"
        Invoke-Command -ScriptBlock { klist.exe purge }

        # I don't really want to handle this so I'll throw it again
        throw $_
    }

    $this.Uri = $SystemCenterUri
    $this.User = $SystemInit.response.user
    $this.Session = $WebSession
    $this.Token = $SystemInit.response.token
    $this.RequestId++
}

$SecurityCenter | Add-Member -MemberType ScriptMethod -Name MakeRequest -Value {
    param ($Module, $Action, $InputObject, $IsJSON = $false)

    if ($IsJSON) {
        $Body = "module={0}&action={1}&token={2}&request_id={3}&input={4}" -f $Module, $Action, $this.Token, $this.RequestId, $InputObject
    } else {
        $Body = "module={0}&action={1}&token={2}&request_id={3}&input={4}" -f $Module, $Action, $this.Token, $this.RequestId, [System.Web.HttpUtility]::UrlEncode(($InputObject | ConvertTo-Json -Compress -Depth 50))
    }

    $Result = $null

    try {
        $Result = Invoke-RestMethod -Uri $this.URI -Method Post -Body $Body -WebSession $this.Session
    } catch {
        ipconfig.exe /flushdns | Out-Null
        nbtstat.exe -R | Out-Null
		
		# requires admin to run?
        klist.exe purge | Out-Null

        # I don't really want to handle this so I'll throw it again
        throw $_
    }

    if ($Result.GetType().Name -eq "String") {
        $Result = ConvertFrom-LargeJson -json $Result
    }

    if ($Result.error_code -ne 0) {
        Write-Debug "Error: $($Result.error_code) - $($result.error_msg)"
    }

    if ($Result.error_code -eq 12) {
        Write-Warning "Unable to perform request.  You must re-SystemInit with your certificate before making any more requests"

        # Clear Kerberos Tickets (http://blogs.technet.com/b/askds/archive/2008/05/14/troubleshooting-kerberos-authentication-problems-name-resolution-issues.aspx)
        ipconfig.exe /flushdns | Out-Null
        nbtstat.exe -R | Out-Null
        klist.exe purge | Out-Null
    }

    $this.RequestId++

    return $Result
}