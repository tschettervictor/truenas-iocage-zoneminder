#!/bin/sh
# Build an iocage jail under TrueNAS 13.0 with zoneminder
# git clone https://github.com/tschettervictor/truenas-iocage-zoneminder

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
#POOL_PATH=""
JAIL_NAME="zoneminder"
HOST_NAME=""
DATABASE="mysql"
#DB_PATH=""
#CONFIG_PATH=""
CONFIG_NAME="zoneminder-config"

# Check for zoneminder-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"
INCLUDES_PATH="${SCRIPTPATH}"/includes

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by vaultwarden-config
if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
JAIL_INTERFACES="vnet0:bridge0"
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
#if [ -z "${POOL_PATH}" ]; then
#  echo 'Configuration error: POOL_PATH must be set'
#  exit 1
#fi
#if [ -z "${HOST_NAME}" ]; then
#  echo 'Configuration error: HOST_NAME must be set'
#  exit 1
#fi

# If DB_PATH and CONFIG_PATH weren't set, set them
#if [ -z "${DB_PATH}" ]; then
#  DB_PATH="${POOL_PATH}"/zoneminder/db
#fi
#if [ -z "${CONFIG_PATH}" ]; then
#  CONFIG_PATH="${POOL_PATH}"/zoneminder/config
#fi

#if [ "${DB_PATH}" = "${CONFIG_PATH}" ]
#then
#  echo "DB_PATH and CONFIG_PATH must be different."
#  exit 1
#fi

# Sanity check DB_PATH and CONFIG_PATH must be different from POOL_PATH
#if [ "${DB_PATH}" = "${POOL_PATH}" ] || [ "${CONFIG_PATH}" = "${POOL_PATH}" ] 
#then
#  echo "DB_PATH and CONFIG_PATH must be different from POOL_PATH!"
#  exit 1
#fi

# Extract IP and netmask, sanity check netmask
IP=$(echo ${JAIL_IP} | cut -f1 -d/)
NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]
then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
then
  NETMASK="24"
fi

#####
#
# Jail Creation
#
#####

# List packages to be auto-installed after jail creation
cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "nano",
  "go",
  "zoneminder",
  "fcgiwrap",
  "mysql80-server",
  "mysql-connector-java",
  "nginx"
  ]
}
__EOF__

# Create the jail and install previously listed packages
if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
	echo "Failed to create jail"
	exit 1
fi
rm /tmp/pkg.json

#####
#
# Directory Creation and Mounting
#
#####

iocage exec "${JAIL_NAME}" mkdir -p /mnt/includes
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/mysql
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/nginx/conf.d
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/php-fpm.d
iocage fstab -a "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

iocage exec "${JAIL_NAME}" cp -f /mnt/includes/php.ini /usr/local/etc/php.ini
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/php-fpm.conf /usr/local/etc/php-fpm.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/php-fpm.d/zoneminder.conf /usr/local/etc/php-fpm.d/zoneminder.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/nginx/conf.d/zoneminder.conf /usr/local/etc/nginx/conf.d/zoneminer.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/mysql/my.cnf /usr/local/etc/mysql/my.cnf

# Enable nginx
iocage exec "${JAIL_NAME}" sysrc -f /etc/rc.conf nginx_enable="YES"

# Enable MySQL
iocage exec "${JAIL_NAME}" sysrc -f /etc/rc.conf mysql_enable="YES"

# Enable fcgi_wrapper for nginx
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_enable="YES"
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_user="www"
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_socket_owner="www" 
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_flags="-c 4"

# Enable PHP
iocage exec "${JAIL_NAME}" sysrc php_fpm_enable="YES"

# Enable ZoneMinder
iocage exec "${JAIL_NAME}" sysrc zoneminder_enable="YES"

# Generate self-signed certificate to allow secure connections from the very beginning
# User should configure their own certificate and key using plugin options
#if [ ! -d "/usr/local/etc/ssl" ]; then
#    mkdir -p /usr/local/etc/ssl
#fi
#/usr/bin/openssl req -new -newkey rsa:2048 -days 366 -nodes -x509 -subj "/O=Temporary Certificate Please Replace/CN=*" \
#		 -keyout /usr/local/etc/ssl/key.pem -out /usr/local/etc/ssl/cert.pem

# Start services
iocage exec "${JAIL_NAME}" service nginx start 2>/dev/null
iocage exec "${JAIL_NAME}" service php-fpm start 2>/dev/null
iocage exec "${JAIL_NAME}" service fcgiwrap start 2>/dev/null 
iocage exec "${JAIL_NAME}" service mysql-server start 2>/dev/null

# Database Setup
MYSQLROOT="password"
DB="zm"
ZM_PASS="zmpass"
ZM_USER="zmuser"

# Configure mysql
iocage exec "${JAIL_NAME}" mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQLROOT}';CREATE DATABASE ${DB};CREATE USER '${ZM_USER}'@'localhost' IDENTIFIED BY '${ZM_PASS}';GRANT SELECT,INSERT,UPDATE,DELETE ON ${DB}.* TO '${ZM_USER}'@'localhost';FLUSH PRIVILEGES;";
#mysql -u root -p"${TMPPW}" --connect-expired-password <<-EOF
#ALTER USER 'root'@'localhost' IDENTIFIED BY '${PASS}';
#CREATE USER '${USER}'@'localhost' IDENTIFIED BY '${PASS}';
#CREATE DATABASE ${DB} CHARACTER SET utf8;
#GRANT ALL PRIVILEGES ON *.* TO '${USER}'@'localhost' WITH GRANT OPTION;
#GRANT ALL PRIVILEGES ON ${DB}.* TO '${USER}'@'localhost';
#FLUSH PRIVILEGES;
#EOF

# Make the default log directory
iocage exec "${JAIL_NAME}" mkdir /var/log/zm
iocage exec "${JAIL_NAME}" chown www:www /var/log/zm

#Setup Database
# zm.conf should not be edited. Instead, create a zm-freenas.conf under
# zoneminder directory. This should make it survice plugin updates, too.
touch /usr/local/etc/zoneminder/zm-freenas.conf
echo "ZM_DB_NAME=${DB}" >> /usr/local/etc/zoneminder/zm-freenas.conf
echo "ZM_DB_USER=${ZM_USER}" >> /usr/local/etc/zoneminder/zm-freenas.conf
echo "ZM_DB_PASS=${ZM_PASS}" >> /usr/local/etc/zoneminder/zm-freenas.conf

#Import Database
iocage exec "${JAIL_NAME}" mysql -u ${USER} -p${PASS} ${DB} < /usr/local/share/zoneminder/db/zm_create.sql

# Create Zoneminder data directories 
iocage exec "${JAIL_NAME}" su -m www -c 'mkdir /var/db/zoneminder/events'
iocage exec "${JAIL_NAME}" su -m www -c 'mkdir /var/db/zoneminder/images'

# Restart the services after everything has been setup
iocage exec "${JAIL_NAME}" service mysql-server restart 2>/dev/null
iocage exec "${JAIL_NAME}" service fcgiwrap restart 2>/dev/null 
iocage exec "${JAIL_NAME}" service php-fpm restart 2>/dev/null
iocage exec "${JAIL_NAME}" service nginx restart 2>/dev/null

# Start Zoneminder service after everything has been setup
iocage exec "${JAIL_NAME}" service zoneminder start 2>/dev/null
