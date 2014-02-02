Short overview on features
==========================

## Directory layout ##

There are three distinct directories that can be set in the configuration file. 

1. configuration directory
1. log file directory
1. data directory

### Configuration directory ###

Usually there are two main files there - the main rsyncmachine.conf
config file and the config file for the logging directives,
rsyncmachine\_logging.conf. The location of the first one does not
need to be here, since it has to be supplied on the commandline anyway,
but it is a good habit to keep configs together.

The logging configuration must be here. It can be altered according to
the syntax requirements of the log4perl module. By default it is
configured to call a subroutine in the main program to retrieve the
location of the logfile directory.

Other optional files in this directory configure exclude files for each
backup location in the rsync default format. The name of the file must
conform to the following convention:

    exclude_<source_name>.txt

where source\_name equals the name of the backup directory that will
hold the synced data. This name is the concatenation of the hostname and
the directory/rsyncmodule name with every slash converted to an
underscore.

Example:

	Source: rsync://foo.bar.org/photos/   
	Datapath: foo_photos/   
	Exclude filename: exclude_foo_photos.txt

	Source: baz.bar.org:/data/music/   
	Datapath: baz_data_music/   
	Exclude filename: exclude_baz_data_music.txt

### Log file directory ###

The script produces several log files during operation. There is one
global rsyncmachine.log file providing details about the overall
operation and progress and this is the place where to look at, when
things go wrong.

For each source there is also a logfile, containing the output of the
rsync operation itself, the format is described in the rsyncd.conf
manual pages. The used rsync format string is: `"%B %U %10l %M %i %f %L"`,
providing this information about each file from the source:

 - mode bits
 - user id
 - size
 - modified date
 - rsync status
 - filename 
 - (possibly soft link information)

Additionally, the graphs for the rrdtool output are stored in this
directory.


### Data directory ###

This is the directory where all the copied files are stored in
subdirectories. For each backup run there is a single directory with the
naming convention: `yyyy-mm-dd-hhmmss`. The last successful directory is
linked additionally as "Latest".

Below each backup directory from each run, there are as many
subdirectories as are individual sources listed in the configuration
file.

As time progresses, usually one new top-level directory is created on
each cron run, normally each hour. Since the default time settings are
to keep 24 hours of hourly backups and daily backups for the last 30
days, at the end of each backup run the directories that are no longer
needed are deleted to conserve disk space.

During the backup, the directory´s name ends with ".inProgress" to
distinguish between already completed backups and backups currently in
work.

If an error occurs during backup and only a subset of the sources could
be successfully backed up, the backup directoy gets renamed to
".partial" to indicate that the error happened and "Latest" still points
to the last successful backup. `rsyncmachine.pl` exits then with error code 1
and usually - when run from a cron job - this gets reported as error via
mail. This depends on your used cron daemon. You have to investigate and
remedy the situation yourself then.

If a backup specifies only directories from one host and this host could
not be reached, then `rsyncmachine.pl` assumes that this host is shut down
normally and exits with a success error code to avoid unneccessary
mails for normal desktop machines. `rsyncmachine.pl` tries to determine
the network connectivity before actually backing up the machine and can
report connectivity issues e.g. in the growl notification. When you are
using normal targets via ssh or rsync daemons, `rsyncmachine.pl` tries
to do a quick TCP connection to the target to see if it's alive. If you
specified one of the special connection methods in your config file,
the connectivity test is using rsync and your actual parameters, so this
is slower.


## Notifications and reports ##

There is a builtin method of using growl, a program that many Mac OS X
users prefer, to notify you about performed backups and their status.

You can start `rsyncmachine.pl` with the `--growlregister` argument and 
`rsyncmachine.pl` registers itself at the host given in the configuration
file with four different notification categories:

 - Critical
 - Error
 - Warning
 - Information

Currently only Error and Information are used. You can configure growl
individually for each type of notification and decide on the
style/colour of the notification and if it shall remain on screen.

Also, at the end of each backup run, some statistics about the backup
are being written into a rrdtool database. An accompanying small script
can be used to create png images from the database to graph:

 - free disk space
 - age in days of the oldest backup available
 - total number of files transferred in this backup run
 - total size in bytes transferred in this backup run
 - total number of files that the backup consists of, independently if
   they have been transferred (= if they have been modified)
 - total size of the backed up data

This is an example image for [weekly transferred
files](../logs/graph_transferred_files_week.png).



<!--
vim:tw=72:si:ai:tabstop=4:sw=4:filetype=markdown
-->
