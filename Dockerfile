#Stage 1 : builder debian image
FROM debian:bullseye as builder

# properly setup debian sources
ENV DEBIAN_FRONTEND noninteractive
RUN echo "deb http://http.debian.net/debian bullseye main\n\
deb-src http://http.debian.net/debian bullseye main\n\
deb http://http.debian.net/debian bullseye-updates main\n\
deb-src http://http.debian.net/debian bullseye-updates main\n\
deb http://deb.debian.org/debian-security bullseye-security main\n\
deb-src http://deb.debian.org/debian-security bullseye-security main\n\
" > /etc/apt/sources.list

# install package building helpers
# rsyslog for logging (ref https://github.com/stilliard/docker-pure-ftpd/issues/17)
RUN apt-get -y update && apt-get -y install apt-utils && apt-get -y dist-upgrade && \
	apt-get -y --fix-missing install dpkg-dev debhelper &&\
	apt-get -y build-dep pure-ftpd


# Build from source - we need to remove the need for CAP_SYS_NICE and CAP_DAC_READ_SEARCH
RUN mkdir /tmp/pure-ftpd && \
	cd /tmp/pure-ftpd && \
	chown _apt:root . && chmod 0775 . && \
	apt-get source pure-ftpd && \
	cd pure-ftpd-* && \
	{ echo "Running configure script..."; \
	  ./configure --enable-largefile --localstatedir=/ \
		--with-altlog --with-cookie --with-diraliases --with-extauth --with-ftpwho \
		--with-language=english --with-peruserlimits --with-privsep --with-puredb \
		--with-quotas --with-ratios --with-throttling --with-uploadscript \
		--with-virtualhosts --with-implicittls --with-paranoidmsg --with-tls \
		--with-sysquotas --with-virtualchroot > /tmp/configure.log 2>&1 || { \
	  cat /tmp/configure.log; exit 1; }; } && \
	sed -i '/CAP_SYS_NICE,/d; /CAP_DAC_READ_SEARCH/d; s/CAP_SYS_CHROOT,/CAP_SYS_CHROOT/;' src/caps_p.h && \
	{ echo "Running dpkg-buildpackage..."; dpkg-buildpackage -b -uc > /tmp/build.log 2>&1 || { cat /tmp/build.log; exit 1; }; }


#Stage 2 : actual pure-ftpd image
FROM debian:bullseye-slim

# feel free to change this ;)
LABEL maintainer "Andrew Stilliard <andrew.stilliard@gmail.com>"

# install dependencies
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get -y update && apt-get -y install apt-utils && apt-get -y dist-upgrade && \
	apt-get --no-install-recommends --yes install \
	libc6 \
	libcap2 \
	libmariadb3 \
	libpam0g \
	libsodium23 \
	libssl1.1 \
	lsb-base \
	openbsd-inetd \
	openssl \
	perl \
	rsyslog

COPY --from=builder /tmp/pure-ftpd/*.deb /tmp/pure-ftpd/

# install the new deb files
RUN dpkg -i /tmp/pure-ftpd/pure-ftpd-common*.deb &&\
	dpkg -i /tmp/pure-ftpd/pure-ftpd_*.deb && \
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-ldap_*.deb && \
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-mysql_*.deb && \
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-postgresql_*.deb && \
	rm -Rf /tmp/pure-ftpd 

# prevent pure-ftpd upgrading
RUN apt-mark hold pure-ftpd pure-ftpd-common

# setup ftpgroup and ftpuser
RUN groupadd ftpgroup &&\
	useradd -g ftpgroup -d /home/ftpusers -s /dev/null ftpuser

# configure rsyslog logging
RUN echo "" >> /etc/rsyslog.conf && \
	echo "#PureFTP Custom Logging" >> /etc/rsyslog.conf && \
	echo "ftp.* /var/log/pure-ftpd/pureftpd.log" >> /etc/rsyslog.conf && \
	echo "Updated /etc/rsyslog.conf with /var/log/pure-ftpd/pureftpd.log"

# setup run/init file
COPY run.sh /run.sh
RUN chmod u+x /run.sh

# cleaning up
RUN apt-get -y clean \
	&& apt-get -y autoclean \
	&& apt-get -y autoremove \
	&& rm -rf /var/lib/apt/lists/*

# default publichost, you'll need to set this for passive support
ENV PURE_FTPD_PASSIVE_IP localhost

# couple available volumes you may want to use
VOLUME ["/home/ftp", "/etc/pure-ftpd/passwd", "/etc/pure-ftpd/puredb"]

# startup
CMD /run.sh \
	--createhomedir \
	--noanonymous \
	--nochmod \
	--forcepassiveip=$PURE_FTPD_PASSIVE_IP

EXPOSE 21 38801-38864
