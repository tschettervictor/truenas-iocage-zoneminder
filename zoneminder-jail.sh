#!/bin/sh

#Enable nginx
sysrc -f /etc/rc.conf nginx_enable="YES"
#Enable MySQL
sysrc -f /etc/rc.conf mysql_enable="YES"
#Enable fcgi_wrapper for nginx
sysrc -f /etc/rc.conf fcgiwrap_enable="YES"
sysrc -f /etc/rc.conf fcgiwrap_user="www"
sysrc -f /etc/rc.conf fcgiwrap_socket_owner="www" 
sysrc -f /etc/rc.conf fcgiwrap_flags="-c 4"
#Enable PHP
sysrc -f /etc/rc.conf php_fpm_enable="YES"
#Enable ZoneMinder
sysrc -f /etc/rc.conf zoneminder_enable="YES"

# Generate self-signed certificate to allow secure connections from the very beginning
# User should configure their own certificate and key using plugin options
if [ ! -d "/usr/local/etc/ssl" ]; then
    mkdir -p /usr/local/etc/ssl
fi
/usr/bin/openssl req -new -newkey rsa:2048 -days 366 -nodes -x509 -subj "/O=Temporary Certificate Please Replace/CN=*" \
		 -keyout /usr/local/etc/ssl/key.pem -out /usr/local/etc/ssl/cert.pem

# Start the service
service nginx start 2>/dev/null
service php-fpm start 2>/dev/null
service fcgiwrap start 2>/dev/null 
service mysql-server start 2>/dev/null

# Database Setup
USER="dbadmin"
# Bug in the sql script there is a default use which i cant fix without breaking other things
DB="zm"

# Save the config values
echo "$DB" > /root/dbname
echo "$USER" > /root/dbuser
export LC_ALL=C
cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1 > /root/dbpassword
PASS=`cat /root/dbpassword`

echo "Database User: $USER"
echo "Database Password: $PASS"

if [ -e "/root/.mysql_secret" ] ; then
   # Mysql > 57 sets a default PW on root
   TMPPW=$(cat /root/.mysql_secret | grep -v "^#")
   echo "SQL Temp Password: $TMPPW"

# Configure mysql
mysql -u root -p"${TMPPW}" --connect-expired-password <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${PASS}';
CREATE USER '${USER}'@'localhost' IDENTIFIED BY '${PASS}';
CREATE DATABASE ${DB} CHARACTER SET utf8;
GRANT ALL PRIVILEGES ON *.* TO '${USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON ${DB}.* TO '${USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Make the default log directory
mkdir /var/log/zm
chown www:www /var/log/zm

else
   # Mysql <= 56 does not

# Configure mysql
mysql -u root <<-EOF
UPDATE mysql.user SET Password=PASSWORD('${PASS}') WHERE User='root';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
CREATE USER '${USER}'@'localhost' IDENTIFIED BY '${PASS}';
CREATE DATABASE ${DB} CHARACTER SET utf8;
GRANT ALL PRIVILEGES ON *.* TO '${USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON ${DB}.* TO '${USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

#Setup Database
# zm.conf should not be edited. Instead, create a zm-freenas.conf under
# zoneminder directory. This should make it survice plugin updates, too.
touch /usr/local/etc/zoneminder/zm-freenas.conf
echo "ZM_DB_NAME=${DB}" >> /usr/local/etc/zoneminder/zm-freenas.conf
echo "ZM_DB_USER=${USER}" >> /usr/local/etc/zoneminder/zm-freenas.conf
echo "ZM_DB_PASS=${PASS}" >> /usr/local/etc/zoneminder/zm-freenas.conf

#Import Database
mysql -u ${USER} -p${PASS} ${DB} < /usr/local/share/zoneminder/db/zm_create.sql

# Create Zoneminder data directories 
su -m www -c 'mkdir /var/db/zoneminder/events'
su -m www -c 'mkdir /var/db/zoneminder/images'

# Restart the services after everything has been setup
service mysql-server restart 2>/dev/null
service fcgiwrap restart 2>/dev/null 
service php-fpm restart 2>/dev/null
service nginx restart 2>/dev/null

# Start Zoneminder service after everything has been setup
service zoneminder start 2>/dev/null

# Output the relevant database details
echo "Database User: $USER" > /root/PLUGIN_INFO
echo "Database Password: $PASS" >> /root/PLUGIN_INFO
echo "Database Name: $DB" >> /root/PLUGIN_INFO
