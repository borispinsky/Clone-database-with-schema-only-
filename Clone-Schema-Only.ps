$ErrorActionPreference = "stop" 
$SourceDB ="NORTHWND"
$TargetDB ="NORTHWND_SCHEMA_ONLY"
$SourceServerInstance ="DATASITEPC"
$TargetServerInstance ="DATASITEPC"
$CreaateDBsql = "CREATE DATABASE "+ $TargetDB +";"
$DACPAC_File = "C:\export\output_current_version.dacpac" 
$OutputSQL ="C:\export\output1.sql"

$PathVariables=$env:Path
IF (-not $PathVariables.Contains( "C:\Program Files (x86)\Microsoft SQL Server\140\DAC\bin")) 
{ 
write-host "SQLPackage.exe path is not found, Update the environment variable" 
$env:Path = $env:Path + ";C:\Program Files (x86)\Microsoft SQL Server\140\DAC\bin;"  
} 
Invoke-Sqlcmd -Query $CreaateDBsql -ServerInstance $TargetServerInstance 
sqlpackage.exe /TargetFile:$DACPAC_File /Action:Extract /SourceServerName:$SourceServerInstance /SourceDatabaseName:$SourceDB  
SqlPackage.exe /Action:Script /SourceFile:$DACPAC_File /TargetServerName:$TargetServerInstance /TargetDatabaseName:$TargetDB /OutputPath:$OutputSQL -ErrorAction Stop
Invoke-Sqlcmd -InputFile $OutputSQL  -ServerInstance $TargetServerInstance
