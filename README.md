rsyncmachine
============

Perl script that automates backups using the hard-link feature of rsync,
thereby keeping consumed diskspace at a minimum.

rsyncmachine.pl will create incremental backups using rsync's hard
links mechanism via --link-dest. The default intervals for retained
backups are similar to settings of other backup applications and can be
changed in the configuration file.

##Version##

This documentation refers to rsyncmachine version 0.10.5

##Synopsis##

rsyncmachine.pl [--help|--version|--growlregister|--man] configurationfile

###Options###

--help
	Print a brief help message.

--version
	Print the version number.

--growlregister
	Sends the growl registration packet to the growl server.

--man
	Print the complete pod documentation. Note that this will
	only work, if you have the perldoc program available on your
	system.

###Arguments###

configurationfile
	Contains the settings for an instance of this program.

##Details##

rsyncmachine.pl will per default create backups as follows:

- hourly backups for the past 24 hours
- daily backups for the past 30 days
- weekly backups for all previous months until the disk is full

rsyncmachine.pl copies the files from remote servers or local
directories to a local directory defined in the configuration file.
Multiple source locations gan be given, even from multiple hosts. The
source syntax supported by this program are:

- rsync://[user@]host.fqdn.tld/module/
- [user@]host.fqdn.tld::module/
- [user@]host.fqdn.tld:/path/to/be/backed/up/
- /path/to/be/backed/up/

Please note the trailing slashes, this means, that the contents of the
directory given as source is copied into one subdirectory of the backup
location with an "escaped" directory name, replacing / with _ etc.

If you have not backed up for a longer time rsyncmachine determines the
amount of space needed and if that is not available it successively
deletes the oldest oldest backups. The last one is preserved though and
an error generated, if there is still not enough space.

The directories for the backups, configuration and logfiles, as well as
the values of retained backups can be changed in a configuration file,
some values that should not normally be changed are defined in global
variables at the beginning of this script.

<!--
vim:tw=72:sw=4:ai:si
-->
