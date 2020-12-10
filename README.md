# Clone-database-with-schema-only
Clone database with schema only using SqlPackage.exe utility

A few days ago one of my clients ask me to build a script that will clone database with schema only (with empty tables). 
One of my options was to use SQL Server Management Objects (SMO) with .net or PowerShell, but it could be a tricky especially with all kind of object dependencies.
I was surprised to figure out that it’s could be much simpler with SqlPackage.exe! 
It’s could be done with four simple steps in powershell, but first Download the latest version of SqlPackage.exe:
https://docs.microsoft.com/en-us/sql/tools/sqlpackage?view=sql-server-ver15

1.	Create an empty database.
2.	Create dacpac from you source database with Extract action.
3.	Create TSQL script with Script action.
4.	Run the script against your empty database.


*** Disclaimer: this solution won’t work if you source database has orphaned users. 
