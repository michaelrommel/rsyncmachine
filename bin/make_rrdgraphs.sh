#! /bin/sh

#
# you can either configure the full path name of the rsyncmachine.pl
# log directory or simply call this with the current working directory
# in the log dir
#

#RRDATAPATH=/var/volumes/backup/logs
RRDATAPATH=.
RRDATABASE=${RRDATAPATH}/rsyncmachine.rrd

DS="total_size transferred_size total_files transferred_files disk_free oldest_backup_age"

for ds in $DS; do
  rrdtool graph ${RRDATAPATH}/graph_${ds}_week.png \
	--end now --start end-604800 \
	--pango-markup \
	--watermark '<span foreground="#cc6600" font-family="sans" font="6.5">RSYNCMACHINE / M. ROMMEL</span>' \
	DEF:ds=${RRDATABASE}:${ds}:AVERAGE \
	LINE1:ds#0000FF:"${ds}\l"
done

for ds in $DS; do
  rrdtool graph ${RRDATAPATH}/graph_${ds}_month.png \
	--end now --start end-2678400 \
	--pango-markup \
	--watermark '<span foreground="#cc6600" font-family="sans" font="6.5">RSYNCMACHINE / M. ROMMEL</span>' \
	DEF:ds=${RRDATABASE}:${ds}:AVERAGE \
	LINE1:ds#0000FF:"${ds}\l"
done

for ds in $DS; do
  rrdtool graph ${RRDATAPATH}/graph_${ds}_year.png \
	--end now --start end-31536000 \
	--pango-markup \
	--watermark '<span foreground="#cc6600" font-family="sans" font="6.5">RSYNCMACHINE / M. ROMMEL</span>' \
	DEF:ds=${RRDATABASE}:${ds}:AVERAGE \
	LINE1:ds#0000FF:"${ds}\l"
done
