## MS-SQL Versioning
Utility for audit all DDL changes in database.  
You could view when who and what was changed in your DB. Scripts can add versions to all objects automatically. 

#### Examples
Changes are stored in dbo.DatabaseAudit table.  
From [examples.sql](/blob/master/examples.sql)  
 
![dbo.DatabaseAudit](/blob/master/content/database_audit.png "dbo.DatabaseAudit")

Version and last update user from extended properties of object   

![Extended properties](/blob/master/content/extended_properties.png "Extended properties")

#### Usage
1. Open [deploy.sql](/blob/master/deploy.sql) script
2. Change database in first line
3. Run script on your db
4. Update same object
5. View changes in dbo.DatabaseAudit table


*You are welcome for contributing )*
