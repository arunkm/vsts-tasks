# For more information on the VSTS Task SDK:
# https://github.com/Microsoft/vsts-task-lib

[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation
try {
    # Import the localized strings.
    Import-VstsLocStrings "$PSScriptRoot\task.json"

    # Load utility functions
    . "$PSScriptRoot\utilities.ps1"
    Import-Module $PSScriptRoot\ps_modules\ServiceFabricHelpers

    # Get inputs.
    $serviceConnectionName = Get-VstsInput -Name serviceConnectionName -Require
    $connectedServiceEndpoint = Get-VstsEndpoint -Name $serviceConnectionName -Require
    $composeFilePath= Get-SinglePathOfType (Get-VstsInput -Name composeFilePath -Require) Leaf -Require
    $applicationName = Get-VstsInput -Name applicationName -Require
    $deployTimeoutSec = Get-VstsInput -Name deployTimeoutSec
    $removeTimeoutSec = Get-VstsInput -Name removeTimeoutSec
    $getStatusTimeoutSec = Get-VstsInput -Name getStatusTimeoutSec

    $deployParameters = @{
        'ApplicationName' = $applicationName
        'Compose' = $composeFilePath
    }
    $removeParameters = @{
        'Force' = $true
    }
    $getStatusParameters = @{
        'ApplicationName' = $applicationName
    }

    # Connect to the cluster
    $clusterConnectionParameters = @{}
    Connect-ServiceFabricClusterFromServiceEndpoint -ClusterConnectionParameters $clusterConnectionParameters -ConnectedServiceEndpoint $connectedServiceEndpoint

    $repositoryCredentials = Get-VstsInput -Name repositoryCredentials -Require
    switch ($repositoryCredentials) {
        "Endpoint"
        {
            $dockerRegistryEndpointName = Get-VstsInput -Name dockerRegistryEndpointName -Require
            $dockerRegistryEndpoint = Get-VstsEndpoint -Name $dockerRegistryEndpointName -Require
            $authParams = $dockerRegistryEndpoint.Auth.Parameters
            $username = $authParams.username
            $password = $authParams.password
            $isEncrypted = $false
        }
        "UsernamePassword"
        {
            $username = Get-VstsInput -Name repositoryUserName -Require
            $password = Get-VstsInput -Name repositoryPassword -Require
            $isEncrypted = (Get-VstsInput -Name passwordEncrypted -Require) -eq "true"
        }
    }

    if ($repositoryCredentials -ne "None")
    {
        if ((-not $isEncrypted) -and $connectedServiceEndpoint.Auth.Parameters.ServerCertThumbprint)
        {
            $thumbprint = $connectedServiceEndpoint.Auth.Parameters.ServerCertThumbprint

            $cert = Get-Item -Path "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
            if($cert -ne $null)
            {
                Write-Host (Get-VstsLocString -Key EncryptingPassword)
                $password = Invoke-ServiceFabricEncryptText -Text $password -CertStore -CertThumbprint $thumbprint -StoreName "My" -StoreLocation CurrentUser
                $isEncrypted = $true
            }
            else
            {
                Write-Host (Get-VstsLocString -Key CertificateNotFound)
            }
        }

        $deployParameters['RepositoryUserName'] = $username
        $deployParameters['RepositoryPassword'] = $password
        $deployParameters['PasswordEncrypted'] = $isEncrypted
    }

    if ($deployTimeoutSec)
    {
        $deployParameters['TimeoutSec'] = $deployTimeoutSec
    }
    if ($removeTimeoutSec)
    {
        $removeParameters['TimeoutSec'] = $removeTimeoutSec
    }
    if ($getStatusTimeoutSec)
    {
        $getStatusParameters['TimeoutSec'] = $getStatusTimeoutSec
    }

    $existingApplication = Get-ServiceFabricDockerComposeApplicationStatusPaged @getStatusParameters
    if ($existingApplication -ne $null)
    {
        Write-Host (Get-VstsLocString -Key RemovingApplication -ArgumentList $applicationName)
        $removeParameters['ApplicationName'] = $applicationName
        Remove-ServiceFabricDockerComposeApplication @removeParameters

        do
        {
            Write-Host (Get-VstsLocString -Key WaitingForRemoval)
            Start-Sleep -Seconds 3
            $existingApplication = Get-ServiceFabricDockerComposeApplicationStatusPaged @getStatusParameters
        }
        while ($existingApplication -ne $null)
    }

    Write-Host (Get-VstsLocString -Key CreatingApplication)
    New-ServiceFabricDockerComposeApplication @deployParameters
} finally {
    Trace-VstsLeavingInvocation $MyInvocation
}