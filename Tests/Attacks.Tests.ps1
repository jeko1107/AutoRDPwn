# Tests\Attacks.Tests.ps1
#
# Contract: every remote-execution path fails fast when its transport port is
# closed, instead of timing out halfway through the payload copy.
#
# The handlers are resolved through the catalog (action id -> -Handler -> function
# body), so renaming a handler does not break this test - only removing the
# preflight does.

Describe 'port preflight' {

    $entries = @(Get-ArCatalogEntries)

    # Documented transports. 5986 is accepted next to 5985 for WinRM/WinRS so a
    # move to HTTPS does not trip the test; dropping the check does.
    $expected = [ordered]@{
        '1' = @{ Name = 'PSexec'; Ports = @('445') }
        '3' = @{ Name = 'WMI'; Ports = @('135') }
        '4' = @{ Name = 'WinRM'; Ports = @('5985', '5986') }
        '5' = @{ Name = 'WinRS'; Ports = @('5985', '5986') }
        '8' = @{ Name = 'Quick Screen'; Ports = @('5985', '5986') }
    }

    foreach ($id in $expected.Keys) {
        $actionId = [string]$id
        $label = $expected[$id].Name
        $allowedPorts = @($expected[$id].Ports)

        It ('checks the port before ' + $label) {
            $entry = @($entries | Where-Object { $_.Id -eq $actionId })
            Assert-True ($entry.Count -eq 1) `
                ("action id {0} ({1}) must be declared exactly once with New-ARAction" -f $actionId, $label)

            $handlerName = $entry[0].Handler
            $function = Get-ArFunctionAst -Name $handlerName
            Assert-NotNull $function `
                ("handler '{0}' for action {1} ({2}) is not defined in any src\*.ps1" -f $handlerName, $actionId, $label)

            $calls = @(Get-ArCommandAsts -Ast $function.Ast.Body -Name 'Assert-ARPort')
            Assert-True ($calls.Count -gt 0) `
                ("{0} (action {1}, '{2}') does not call Assert-ARPort; a closed transport port would surface as a timeout" -f $handlerName, $actionId, $label)

            $ports = New-Object System.Collections.ArrayList
            foreach ($call in $calls) {
                $parameters = Get-ArCommandParameterMap -CommandAst $call
                $null = $ports.Add([string]$parameters['Port'])
                # The value may be a variable ($target); the binding is what matters.
                Assert-True ($parameters.ContainsKey('Computer')) `
                    ("{0} calls Assert-ARPort without -Computer at {1}:{2}" -f $handlerName, $function.File, $call.Extent.StartLineNumber)
            }

            $hits = @($ports | Where-Object { $allowedPorts -contains $_ })
            Assert-True ($hits.Count -gt 0) `
                ("{0} preflights port(s) {1}; the {2} transport is documented on {3}" -f $handlerName, (($ports | Sort-Object -Unique) -join ', '), $label, ($allowedPorts -join '/'))
        }
    }
}
