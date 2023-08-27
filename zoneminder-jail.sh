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
# General Configuration
#
#####

# Script Default Variables
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
JAIL_NAME="zoneminder"
CONFIG_NAME="zoneminder-config"
# Database Variables
DATABASE="MySQL"
MYSQLROOT=$(openssl rand -base64 15)
DB="zm"
ZM_PASS=$(openssl rand -base64 15)
ZM_USER="zmuser"

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
# If release is 13.1-RELEASE, change to 13.2-RELEASE
if [ "${RELEASE}" = "13.1-RELEASE" ]; then
  RELEASE="13.2-RELEASE"
fi 

#####
#
# Input/Config Sanity Checks
#
#####

# Check that necessary variables were set by zoneminder-config
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
  "zoneminder",
  "fcgiwrap",
  "mysql80-server",
  "openssl",
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
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/mysql/conf.d
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/nginx/conf.d
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/php-fpm.d
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/zoneminder
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/ssl
iocage exec "${JAIL_NAME}" mkdir -p /var/db/zoneminder/events
iocage exec "${JAIL_NAME}" mkdir -p /var/db/zoneminder/images
iocage exec "${JAIL_NAME}" mkdir -p /var/log/zm
iocage exec "${JAIL_NAME}" chown www:www /var/log/zm
iocage fstab -a "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

#####
#
# Installation
#
#####

# Enable and configure services
iocage exec "${JAIL_NAME}" sysrc nginx_enable="YES"
iocage exec "${JAIL_NAME}" sysrc mysql_enable="YES"
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_enable="YES"
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_user="www"
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_socket_owner="www" 
iocage exec "${JAIL_NAME}" sysrc fcgiwrap_flags="-c 4"
iocage exec "${JAIL_NAME}" sysrc php_fpm_enable="YES"
iocage exec "${JAIL_NAME}" sysrc zoneminder_enable="YES"

# Generat SSL Certificate for Nginx
iocage exec "${JAIL_NAME}" 'openssl req -new -newkey rsa:2048 -days 366 -nodes -x509 -subj "/O=ZoneMinder Home/CN=*" -keyout /usr/local/etc/ssl/key.pem -out /usr/local/etc/ssl/cert.pem'

# Start services (zoneminder will be started later)
iocage exec "${JAIL_NAME}" service mysql-server start
iocage exec "${JAIL_NAME}" service nginx start
iocage exec "${JAIL_NAME}" service php-fpm start
iocage exec "${JAIL_NAME}" service fcgiwrap start 

# Create, import, and configure database
iocage exec "${JAIL_NAME}" mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQLROOT}';CREATE DATABASE ${DB};CREATE USER '${ZM_USER}'@'localhost' IDENTIFIED BY '${ZM_PASS}';GRANT SELECT,INSERT,UPDATE,DELETE ON ${DB}.* TO '${ZM_USER}'@'localhost';FLUSH PRIVILEGES;";
iocage exec "${JAIL_NAME}" "mysql -u root --password='${MYSQLROOT}' '${DB}' < /usr/local/share/zoneminder/db/zm_create.sql"
iocage exec "${JAIL_NAME}" 'echo "ZM_DB_NAME='${DB}'" > /usr/local/etc/zoneminder/zm-truenas.conf'
iocage exec "${JAIL_NAME}" 'echo "ZM_DB_USER='${ZM_USER}'" >> /usr/local/etc/zoneminder/zm-truenas.conf'
iocage exec "${JAIL_NAME}" 'echo "ZM_DB_PASS='${ZM_PASS}'" >> /usr/local/etc/zoneminder/zm-truenas.conf'

# Copy Necessary Config Files
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/php.ini /usr/local/etc/php.ini
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/php-fpm.conf /usr/local/etc/php-fpm.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/php-fpm.d/zoneminder.conf /usr/local/etc/php-fpm.d/zoneminder.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/nginx/conf.d/zoneminder.conf.ssl /usr/local/etc/nginx/conf.d/zoneminder.conf
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/mysql/my.cnf /usr/local/etc/mysql/conf.d/zoneminder.cnf

# Restart Services and start Zoneminder
iocage exec "${JAIL_NAME}" service mysql-server restart
iocage exec "${JAIL_NAME}" service fcgiwrap restart 
iocage exec "${JAIL_NAME}" service php-fpm restart
iocage exec "${JAIL_NAME}" service nginx restart
iocage exec "${JAIL_NAME}" service zoneminder start

# Save passwords for later reference
echo "${DATABASE} root user is root and password is ${MYSQLROOT}" > /root/${JAIL_NAME}_passwords.txt
echo "Zoneminder database user is ${ZM_USER} and password is ${ZM_PASS}" >> /root/${JAIL_NAME}_passwords.txt

# Restart
iocage restart "${JAIL_NAME}"

echo "---------------"
echo "Installation complete."
echo "---------------"
echo echo "Using your web browser, go to http://${IP}/zm to log in"
echo "---------------"
echo "Database Information"
echo "MySQL Username: root"
echo "MySQL Password: ${MYSQLROOT}"
echo "Zoneminder DB User: ${ZM_USER}"
echo "Zoneminder DB Password: ${ZM_PASS}"
echo "---------------"
echo "All passwords are saved in /root/${JAIL_NAME}_passwords.txt"
