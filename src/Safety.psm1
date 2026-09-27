Set-StrictMode -Version Latest

function Test-ProcessStartIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Expected,
        [Parameter(Mandatory)] [datetime] $Actual,
        [int] $ToleranceMilliseconds = 1000
    )

    try {
        $expectedTime = [DateTimeOffset]::Parse(
            $Expected,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $actualTime = [DateTimeOffset]::Parse(
            $Actual.ToString('o'),
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        return [math]::Abs(($actualTime.UtcDateTime - $expectedTime.UtcDateTime).TotalMilliseconds) -le
            $ToleranceMilliseconds
    }
    catch {
        return $false
    }
}

function Select-UniqueLowestDistance {
    [CmdletBinding()]
    param(
        [object[]] $Candidates,
        [Parameter(Mandatory)] [double] $WindowSeconds
    )

    $inWindow = @($Candidates |
        Where-Object { [double] $_.Distance -le $WindowSeconds } |
        Sort-Object { [double] $_.Distance })
    if ($inWindow.Count -ne 1) {
        return $null
    }
    return $inWindow[0]
}

Export-ModuleMember -Function Test-ProcessStartIdentity, Select-UniqueLowestDistance
