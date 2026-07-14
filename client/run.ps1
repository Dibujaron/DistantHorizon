# Launch the Distant Horizon client. Extra args are passed through to godot,
# e.g.:  .\run.ps1 -- --username=you --password=pw
$env:PATH = "$env:USERPROFILE\scoop\shims;$env:PATH"
godot --path $PSScriptRoot @args
