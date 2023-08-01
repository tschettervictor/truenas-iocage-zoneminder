# truenas-iocage-zoneminder
Script to create an iocage jail on TrueNAS for the latest zoneminder pkg release. This script uses essentially all the components from the original TrueNAS CORE plugin repo, including nginx as the webserver. It will create the database and generate a strong root password and user password for the database system. 

## Status
This script will work with TrueNAS CORE 13.0.  Due to the EOL status of FreeBSD 12.0, it is unlikely to work reliably with earlier releases of FreeNAS.

## Usage

### Prerequisites
This script does not store any data outside the jail at this time, so there are no prerequisites.

### Installation
Download the repository to a convenient directory on your TrueNAS system by changing to that directory and running `git clone https://github.com/tschettervictor/truenas-iocage-zoneminder`.  Then change into the new `truenas-iocage-zoneminder` directory and create a file called `zoneminder-config` with your favorite text editor.  In its minimal form, it would look like this:
```
JAIL_IP="192.168.1.199"
DEFAULT_GW_IP="192.168.1.1"
```
These two option are self explanatory, but you can configure a few others as well.

* JAIL_IP is the IP address for your jail.  You can optionally add the netmask in CIDR notation (e.g., 192.168.1.199/24).  If not specified, the netmask defaults to 24 bits.  Values of less than 8 bits or more than 30 bits are invalid.
* DEFAULT_GW_IP is the address for your default gateway
* JAIL_NAME: The name of the jail, defaults to "zoneminder"
* INTERFACE: The network interface to use for the jail.  Defaults to `vnet0`.
* JAIL_INTERFACES: Defaults to `vnet0:bridge0`, but you can use this option to select a different network bridge if desired.  This is an advanced option; you're on your own here.
* VNET: Whether to use the iocage virtual network stack.  Defaults to `on`.

### Execution
Once you've downloaded the script and prepared the configuration file, run this script (`script zoneminder.log ./zoneminder-jail.sh`).  The script will run for several minutes.  When it finishes, your jail will be created, zoneminder will be installed and configured, and you'll be shown the randomly-generated passwords for the database.

### Notes
- Reinstall is not supported at this time. If you are going to rebuild your jail, make sure to save any needed data.
- This script will install a self-signed cert for use with https.
- Database passwords are stored in your TrueNAS root directory.
