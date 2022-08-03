# OSC
<<<<<<< HEAD
Updated version of Omada Software Controller 'control./tpeap' script + Download URL Debian Bullseye 4.4.15 mongodb binary
=======
Updated version of Omada Software Controller 'control./tpeap' script + Debian Bullseye 4.4.15 mongodb binary
>>>>>>> a43b323e040b8f9acf43a0c2bd6d1a84c592127a

Contains :

** My version of TP-Link's Omada Software Controller's 'control.sh' script linked as '/usr/bin/tpeap'
  A summary of the changes made :

 - Increased compatibility with centralized account management solutions (NIS,LDAP,..)
 - General reorganization of code structure by adding some new functions and renaming others
 - Added looping to remove some duplicate code
 - Standardized function return codes
 - Clarified certain error mesages
 - Corrected/added stdout/stderr redirections where applicable
 - Colorized and changed output formatting
 - Added separate section for user variables
 - Improved checking of startup to not have to wait 5 minutes on immediate startup failure
 - Added check for mongod dependency
 - Added support for splitting startup logs by success/failure
 - Forced stop kill is now based on PID_FILE
 - Now checks for and ensures symbolic link presence to mongod binary before each startup
 - Correction for unused CURL variable
 - Status command now reports on transitional states

** A standalone systemd service file as a replacement for the old-style system-V init script with systemd-generator integration
  that OSC has been using so far, to handle OSC start/stop
  
<<<<<<< HEAD
** (ARM 64 bit only) A text-file containing a Google Drive share-URL to download a gzipped tar archive containing the 'bin' dir contents that resulted from compiling the mongodb-4.4.15 source code
=======
** (ARM 64 bit only) A gzipped tar archive containing the 'bin' dir contents that resulted from compiling the mongodb-4.4.15 source code
>>>>>>> a43b323e040b8f9acf43a0c2bd6d1a84c592127a
  on Debian Bullseye (11) for aarch64/ARM architecture, since i could not find precompiled ARM versions anywhere, except for Ubuntu.
  You should not need more than just to extract this into a directory of your choosing (e.g. /opt/mongodb).
  Unless of course, i'm mistaken in remembering that i compiled statically, in which case you'll have to do it yourself. Shit happens
