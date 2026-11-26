param([string]$VivadoBin='D:/Xilinx/Vivado/2018.3/bin')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
if (-not $env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE='AMD64' }
$taskWork=Join-Path $taskRoot 'sim_work'
New-Item -ItemType Directory -Force $taskWork | Out-Null
$taskFiles=@(Get-ChildItem (Join-Path $taskRoot 'rtl/*.v'))+@(Get-ChildItem (Join-Path $taskRoot 'sim/*.v'))
$taskFiles | ForEach-Object { 'verilog work "'+$_.FullName.Replace('\','/')+'"' } | Set-Content (Join-Path $taskWork 'files.prj') -Encoding ascii
Push-Location $taskWork
try {
    & "$VivadoBin/xvlog.bat" -prj files.prj
    if($LASTEXITCODE -ne 0){throw 'xvlog failed'}
    foreach($taskTop in @('tb_relay_window','tb_relay_system')) {
        & "$VivadoBin/xelab.bat" "work.$taskTop" -s $taskTop
        if($LASTEXITCODE -ne 0){throw 'xelab failed'}
        & "$VivadoBin/xsim.bat" $taskTop -runall -log "../reports/$taskTop.log"
        if($LASTEXITCODE -ne 0){throw 'xsim failed'}
        if(-not (Select-String "../reports/$taskTop.log" -Pattern 'ALL RELAY .* TESTS PASSED' -Quiet)){
            throw "$taskTop did not pass"
        }
    }
    Copy-Item -LiteralPath uart_capture.txt -Destination ../reports/uart_capture.txt -Force
} finally {Pop-Location}
