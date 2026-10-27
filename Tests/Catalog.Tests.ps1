# Tests\Catalog.Tests.ps1
#
# Contract: the action catalog declared with New-ARAction in src\*.ps1 is
# well formed. Read with the AST, so no action is ever invoked and the catalog
# can move between src files without breaking this test.

Describe 'catalog' {

    $entries = @(Get-ArCatalogEntries)

    It 'declares at least one action' {
        Assert-True ($entries.Count -gt 0) 'no New-ARAction call found in src\*.ps1'
    }

    It 'every action declares an id and a handler' {
        $broken = @($entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Id) -or [string]::IsNullOrWhiteSpace($_.Handler) })
        if ($broken.Count -eq 0) { return }
        $detail = @($broken | ForEach-Object { '{0}:{1} (id={2}, handler={3})' -f $_.File, $_.Line, $_.Id, $_.Handler }) -join '; '
        throw ('New-ARAction call without a literal -Id and -Handler: ' + $detail)
    }

    It 'action ids are unique' {
        $duplicates = @($entries | Group-Object Id | Where-Object { $_.Count -gt 1 })
        if ($duplicates.Count -eq 0) { return }
        $detail = @($duplicates | ForEach-Object {
                'id {0} at {1}' -f $_.Name, (($_.Group | ForEach-Object { '{0}:{1}' -f $_.File, $_.Line }) -join ', ')
            }) -join '; '
        throw ('duplicate action ids: ' + $detail)
    }

    It 'documented action ids exist' {
        $documented = New-Object System.Collections.ArrayList
        foreach ($id in @(1, 2, 3, 4, 5, 6, 7, 8)) { $null = $documented.Add([string]$id) }
        foreach ($range in @(@(101, 105), @(201, 204), @(301, 304), @(401, 403), @(501, 503), @(601, 603))) {
            for ($id = $range[0]; $id -le $range[1]; $id++) { $null = $documented.Add([string]$id) }
        }
        # Extra ids are allowed (701-704 exist today); losing a documented one is not.
        $present = @($entries | ForEach-Object { $_.Id })
        $missing = @($documented | Where-Object { $present -notcontains $_ })
        if ($missing.Count -eq 0) { return }
        throw ('documented action ids missing from the catalog: ' + ($missing -join ', '))
    }

    It 'every handler is defined in src' {
        $defined = @(Get-ArFunctionNames)
        $missing = @($entries | Where-Object { $defined -notcontains $_.Handler })
        if ($missing.Count -eq 0) { return }
        $detail = @($missing | ForEach-Object { '"{0}" for id {1} at {2}:{3}' -f $_.Handler, $_.Id, $_.File, $_.Line }) -join '; '
        throw ('action handlers without a function definition in src\*.ps1: ' + $detail)
    }
}
