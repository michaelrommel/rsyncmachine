rsyncmachine.conf
=================

## Source directory definitions ##

The directory source syntax supported by this program are all standard
rsync parameter declarations.

1. /path/to/be/backed/up/
1. rsync://[user@]host.fqdn.tld[:port]/module/
1. [user@]host.fqdn.tld::module/
1. [user@]host.fqdn.tld:/path/to/be/backed/up/

Variant 1) is just a regular copy on the same host.

Variant 2) is using a direct tcp connection to a rsync daemon on 
the source computer, typically on port 873, but a different port can
be specified as well.

Variant 3) is a different way of 2), same functionality, but without the
ability to specify the port of the remote daemon.

Variant 4) is using ssh per default as standard transport mechanism to
connect to the source system and transporting the rsync data stream. rsync
uses the supplied username for both the ssh login and for rsync to
determine the access to the path. Note that rsync per default does not 
provide you with a method of specifying a different port to connect to.

Therefore the syntax model of the configuration file allows to specify
also special connection methods, just like you can on the commandline
and credentials for authentication purposes.


## Special connection methods ##

One quick example is a connection to an ssh daemon running on a non
standard port, e.g. because of port conflicts or for security reasons.
rsync provides you with the `-e` option, where you can define your
remote shell program that shall be used. This parameter can be given
in your JSON structure with the keys `connection` and `password`.

Example:

        "SOURCE_DEFINITIONS" : [
            { "dir"         : "foo.example.org:/data/movies/" },
            { "dir"         : "bar.example.org:/data/ebooks/novels/" },
              "connection"  : "-e 'ssh -p 2222 -l joe'" },
            { "dir"         : "rsync://baz.example.org/photos/" },
            { "dir"         : "sounduser@qux.example.org::music/",
              "connection"  : "-e 'ssh -i /path/to/jims_ssh_identity -l jim qux.example.org'",
              "password"    : "sounduserssecretpassword" },
        ]

Explanation:

1. foo uses ssh
1. bar uses ssh on a non standard port
1. baz uses an rsync daemon
1. qux uses an rsync daemon via a ssh tunnel

The second example shows a standard use of the `-e` parameter.
You specify the remote shell program to use and the parameters needed
to log into the other system, e.g. specifying another port or 
a username. The successful backup of the `/data/ebooks/novels/` 
directory depends on the access rights of the user `joe` in this
example.

The last example is the most complex. The remote host at qux has 
a rsync daemon running, that is shielded from the network, because
it is listening only on the loopback device and can be accessed
only from localhost. The daemon configures several modules that contain
files which need elevated privileges to be backed up. The module is
also password protected.

In order to back up this machine, a user `jim` with normal privileges is
used, that has no password login and the `authorized_keys` file of
ssh specifies exactly which command the user is allowed to execute:

        no-port-forwarding,no-pty,command="/bin/nc 127.0.0.1 873" \
	    ecdsa-sha2-nistp521 AAAAasdfjkl...

That means that jim logs into the machine using ssh and a non password
protected identity file on the backup host, then the forwarding command
`/bin/nc` is started and a connection to the daemon is established.
`rsyncmachine.pl` then authenticates itself for the module `music`
using `sounduser` as the username and the given password from the 
JSON structure.

The password is exported to the environment variable `RSYNC_PASSWORD`.
Since on unix system the environment can be seen from the process list
e.g. with `ps axeww` care should be taken to use this feature. For my
purposes this is sufficient, since there is only one user on the 
backup machine and the environment can be seen only by the user himself
and root, since it is running a Linux OS.

This allows for really sophisticated setups, where transmission and 
possible attack scenarios on the server are minimized.


## Other tips and advices ##

Wherever a host.fqdn.tld is specified, a short hostname may also be used
provided that your name resolver is able to find the source host by that
short name. In any case for the resulting target backup directory the 
.fqdn.tld is stripped, to create shorter directory names. 

**Attention:** Beware of clashes, where you would like to backup from 
host1.domain.com and from host1.domain.org in the same instance of 
`rsyncmachine.pl` and using exactly the same module or path name to 
backup - this would result in identical directories and probably 
clobber your backup.

Please note the trailing slashes, this means, that the contents of the
directory given as source is copied into one subdirectory of the backup
location with an "escaped" directory name, replacing / with _ etc.

An [example configuration file](./conf/rsyncmachine.conf) can be found in the [conf/](./conf/) subdirectory.

For further information, you can read more about the 
[features](./doc/features.md).


<!--
vim:tw=72:sw=4:ai:si:filetype=markdown
-->
