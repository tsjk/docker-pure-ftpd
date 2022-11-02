#stage 1 : builder debian image
FROM debian:bullseye as builder

# Set DEBIAN_FRONTEND to 'noninteractive'
ENV DEBIAN_FRONTEND noninteractive

# properly setup debian sources
RUN echo "deb http://http.debian.net/debian bullseye main\n\
deb-src http://http.debian.net/debian bullseye main\n\
deb http://http.debian.net/debian bullseye-updates main\n\
deb-src http://http.debian.net/debian bullseye-updates main\n\
deb http://deb.debian.org/debian-security bullseye-security main\n\
deb-src http://deb.debian.org/debian-security bullseye-security main\n\
" > /etc/apt/sources.list && \
# install package building helpers
# rsyslog for logging (ref https://github.com/stilliard/docker-pure-ftpd/issues/17)
	apt-get -y update && apt-get -y install apt-utils && apt-get -y dist-upgrade &&\
	apt-get -y --fix-missing install dpkg-dev debhelper &&\
	apt-get -y build-dep pure-ftpd

# Build from source - we need to remove the need for CAP_SYS_NICE and CAP_DAC_READ_SEARCH
RUN mkdir /tmp/pure-ftpd &&\
	cd /tmp/pure-ftpd &&\
	chown _apt:root . && chmod 0775 . &&\
	apt-get source pure-ftpd &&\
	cd pure-ftpd-* &&\
	{ echo "Running configure script...";\
	  ./configure --with-everything\
		--with-diraliases --with-paranoidmsg\
		--with-peruserlimits --with-sysquotas\
		--with-virtualchroot --with-language=english\
		--with-tls --without-bonjour > /tmp/configure.log 2>&1 || {\
	  cat /tmp/configure.log; exit 1; }; } &&\
	sed -i '/CAP_SYS_NICE,/d; /CAP_DAC_READ_SEARCH/d; s/CAP_SYS_CHROOT,/CAP_SYS_CHROOT/;' src/caps_p.h &&\
	{ echo "Running dpkg-buildpackage..."; dpkg-buildpackage -b -uc > /tmp/build.log 2>&1 || { cat /tmp/build.log; exit 1; }; }


#stage 2 : pure-ftpd image
FROM debian:bullseye-slim

LABEL maintainer "Tamas Jantvik <tsjk@hotmaill.com>"

# Set DEBIAN_FRONTEND to 'noninteractive'
ENV DEBIAN_FRONTEND noninteractive

# install dependencies
RUN apt-get -y update && apt-get -y install apt-utils && apt-get -y dist-upgrade &&\
	apt-get --no-install-recommends --yes install\
	libc6\
	libcap2\
	libmariadb3\
	libpam0g\
	libsodium23\
	libssl1.1\
	lsb-base\
	openbsd-inetd\
	openssl\
	perl\
	rsyslog

# copy built packages
COPY --from=builder /tmp/pure-ftpd/*.deb /tmp/pure-ftpd/

# copy entrypoint file
COPY entrypoint.sh /entrypoint.sh

# install the new deb files
RUN dpkg -i /tmp/pure-ftpd/pure-ftpd-common*.deb &&\
	dpkg -i /tmp/pure-ftpd/pure-ftpd_*.deb &&\
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-ldap_*.deb &&\
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-mysql_*.deb &&\
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-postgresql_*.deb &&\
	rm -Rf /tmp/pure-ftpd\
# prevent pure-ftpd upgrading
	apt-mark hold pure-ftpd pure-ftpd-common &&\
# setup ftp group and user
	groupadd ftp &&\
	useradd -g ftp -d /home/ftp -s /dev/null ftp &&\
# configure rsyslog logging
	echo "" >> /etc/rsyslog.conf &&\
	echo "#PureFTP Custom Logging" >> /etc/rsyslog.conf &&\
	echo "ftp.* /var/log/pure-ftpd/pureftpd.log" >> /etc/rsyslog.conf &&\
	echo "Updated /etc/rsyslog.conf with /var/log/pure-ftpd/pureftpd.log" &&\
# cleaning up
	apt-get -y clean\
	&& apt-get -y autoclean\
	&& apt-get -y autoremove\
	&& rm -rf /var/lib/apt/lists/*\
# setup entrypoint file
	&& chmod u+x /entrypoint.sh

# default publichost, you'll need to set this for passive support
ENV PURE_FTPD_PASSIVE_IP localhost

# default ports to expose
EXPOSE 21 38801-38864

# couple available volumes you may want to use
VOLUME ["/home/ftp", "/etc/pure-ftpd/passwd", "/etc/pure-ftpd/puredb"]

# execution of entrypoint
CMD ["/entrypoint.sh", "--createhomedir", "--noanonymous", "--nochmod", "--forcepassiveip=$PURE_FTPD_PASSIVE_IP"]
