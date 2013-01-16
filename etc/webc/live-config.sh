#!/bin/bash
# Setting up Webconverger system as root user
. /etc/webc/functions.sh
. /etc/webc/webc.conf


sub_literal() {
  awk -v str="$1" -v rep="$2" '
  BEGIN {
    len = length(str);
  }

  (i = index($0, str)) {
    $0 = substr($0, 1, i-1) rep substr($0, i + len);
  }

  1'
}

process_options()
{

cmdline_has timezone && /etc/init.d/timezone # process timezone=

# Create a Webconverger preferences to store dynamic FF options
cat > "$prefs" <<EOF
// This file is autogenerated based on cmdline options by live-config.sh. Do
// not edit this file, your changes will be overwriting on the next reboot!

EOF

# If printing support is not installed, prevent printing dialogs from being
# shown
if ! dpkg -s cups 2>/dev/null >/dev/null; then
	echo '// Print support not included, disable print dialogs' >> "$prefs"
	echo 'pref("print.always_print_silent", true);' >> "$prefs"
	echo 'pref("print.show_print_progress", false);' >> "$prefs"
fi

for x in $( cmdline ); do
	case $x in

	debug)
		echo "webc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
		;;

	chrome=*)
		chrome=${x#chrome=}
		dir="/etc/webc/extensions/${chrome}"
		test -d $dir && {
			test -e "$link" && rm -f "$link"
			logs "switching chrome to ${chrome}"
			ln -s "$dir" "$link"
		}
		;;

	hosts=*)
		hosts="$( /bin/busybox httpd -d ${x#hosts=} )"
			wget --timeout=5 "${hosts}" -O /etc/hosts
			if echo $hosts | grep -q whitelist
			then
				: > /etc/resolv.conf
			fi
		;;

	log=*)
		log=${x#log=}
		echo "*.*          @${log}" >> /etc/rsyslog.conf
		logs "Logging to ${log}"
		/etc/init.d/rsyslog restart
		;;

	locale=*)
		locale=${x#locale=}
		for i in /opt/firefox/langpacks/langpack-$locale*; do ln -s $i /opt/firefox/extensions/$(basename $i); done
		echo "pref(\"general.useragent.locale\", \"${locale}\");" >> "$prefs"
		echo "pref(\"intl.accept_languages\", \"${locale}, en\");" >> "$prefs"
		;;

	cron=*)
		cron="$( echo ${x#cron=} | sed 's,%20, ,g' )"		
		cat <<EOC > /etc/cron.d/live-config
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
$cron
EOC
		;;

	homepage=*)
		homepage="$( echo ${x#homepage=} | sed 's,%20, ,g' )"
		echo "browser.startup.homepage=$(echo $homepage | awk '{print $1}')" > /opt/firefox/defaults/preferences/homepage.properties
		;;
	esac
done

if ! cmdline_has noclean
then
cat >> "$prefs" <<EOF
// Enable private browsing and enable all sanitize on shutdown features just
// to be sure we are wiping the slate clean.
pref("privateBrowsingEnabled", true);
pref("browser.privatebrowsing.autostart", true);
pref("privacy.sanitize.sanitizeOnShutdown", true);
pref("privacy.clearOnShutdown.offlineApps", true);
pref("privacy.clearOnShutdown.passwords", true);
pref("privacy.clearOnShutdown.siteSettings", true);
// cpd = Clear Private Data
pref("privacy.cpd.offlineApps", true);
pref("privacy.cpd.passwords", true);
pref("privacy.sanitize.sanitizeOnShutdown", true);
EOF
fi

# Make sure /home has noexec and nodev, for extra security.
# First, just try to remount, in case /home is already a separate filesystem
# (when using persistence, for example).
mount -o remount,noexec,nodev /home 2>/dev/null || (
	# Turn /home into a tmpfs. We use a trick here: after the mount, this
	# subshell will still have the old /home as its current directory, so
	# we can still read the files in the original /home. By passing -C to
	# the second tar invocation, it does a chdir, which causes it to end
	# up in the new filesystem. This enables us to easily copy the
	# existing files from /home into the new tmpfs.
	cd /home
	mount -o noexec,nodev -t tmpfs tmpfs /home
	tar -c . | tar -x -C /home
)

stamp=$( git show $webc_version | grep '^Date' )

test -f ${link}/content/about.xhtml.bak || cp ${link}/content/about.xhtml ${link}/content/about.xhtml.bak
cat ${link}/content/about.xhtml.bak |
sub_literal 'OS not running' "${webc_version} ${stamp}" |
sub_literal 'var aboutwebc = "";' "var aboutwebc = \"$(echo ${install_qa_url} | sed 's,&,&amp;,g')\";" > ${link}/content/about.xhtml

} # end of process_options

update_cmdline() {
	if curl -f -o /etc/webc/cmdline.tmp --retry 3 "$config_url"
	then
		# curl has a bug where it doesn't write an empty file
		touch /etc/webc/cmdline.tmp
		# This file can be empty in the case of an invalidated configuration
		mv /etc/webc/cmdline.tmp /etc/webc/cmdline
	fi
}

# If we have a "cached" version of the configuration on disk,
# copy that to /etc/webc, so we can compare the new version with
# it to detect changes and/or use it in case the new download
# fails.
if test -s /live/image/live/webc-cmdline
then
	cp /live/image/live/webc-cmdline /etc/webc/cmdline
else
	touch /etc/webc/cmdline
fi

/etc/init.d/webconverger

wait_for $live_config_pipe 2>/dev/null

. "/etc/webc/webc.conf"

cmdline_has debug && set -x

cmdline_has noconfig || update_cmdline
process_options

echo ACK > $live_config_pipe

# Try to make /live/image writable
mount -o remount,rw /live/image

# if writable
if touch /live/image
then
	# Cache cmdline in case subsequent boots can't reach $config_url
	cp /etc/webc/cmdline /live/image/live/webc-cmdline

	# Kicks off an upgrade
	mkfifo $upgrade_pipe
else
# /live/image could not be made writable (e.g. live version: booting
# from an iso fs), so just use the new config downloaded
# and skip all the other stuff below
	logs "Not a writable boot medium. Could not cache configuration nor upgrade."
fi

# live-config should restart via systemd and get blocked 
# until $live_config_pipe is re-created
