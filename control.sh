#!/bin/bash
#
# Management script for TP-Link's EAP Controller
#
# Changelog of modifications by Davy Keppens on 24/07/2022 :
#
# - Increased compatibility with centralized account management solutions (NIS,LDAP,..)
# - General reorganization of code structure by adding some new functions and renaming others
# - Added looping to remove some duplicate code
# - Standardized function return codes
# - Added optional accompanying systemd service file tpeap.service as replacement for old-style systemd-generator /etc/init.d/tpeap script
# - Clarified certain error mesages
# - Corrected/added stdout/stderr redirections where applicable
# - Colorized and changed output formatting
# - Added separate section for user variables
# - Improved checking of startup to not have to wait 5 minutes on immediate startup failure
# - Added check for mongod dependency
# - Added support for splitting startup logs by success/failure
# - Forced stop kill is now based on PID_FILE
# - Now checks for and ensures symbolic link presence to mongod binary before each startup
# - Correction for unused CURL variable
# - Status command now reports on transitional states
#

#
# Mandatory user variables (configurable)
#

declare -x JRE_HOME="/opt/jdk1.8.0_321/jre"

#
# Optional user variables (configurable)
#
# - MONGOD_BIN_PATH, JSVC_BIN_PATH and CURL_BIN_PATH will be auto-detected by the script if left unspecified and the binary can be found in the the current user's PATH environment
#   If not, these become mandatory
# - OMADA_RUNAS_USER will default to 'root' if left unspecified
# - OMADA_STD_LOG will default to '${LOG_DIR}/startup.log' if left unspecified
# - OMADA_ERR_LOG will default to '${LOG_DIR}/startup.log' if left unspecified
#

declare MONGOD_BIN_PATH="/opt/mongodb/bin/mongod"
declare JSVC_BIN_PATH=""
declare CURL_BIN_PATH=""
declare OMADA_RUNAS_USER=""
declare -x OMADA_STD_LOG=""
declare -x OMADA_ERR_LOG=""

#
# Declare global variables
#

declare -x NAME="omada"
declare -x DESC="Omada Controller"
declare -x OMADA_HOME="$(dirname "$(dirname "$(readlink -f "${0}" 2>/dev/null)" 2>/dev/null)" 2>/dev/null)"
declare -x LOG_DIR="${OMADA_HOME}/logs"
declare -x WORK_DIR="${OMADA_HOME}/work"
declare -x DATA_DIR="${OMADA_HOME}/data"
declare -x PROPERTY_DIR="${OMADA_HOME}/properties"
declare -x AUTOBACKUP_DIR="${DATA_DIR}/autobackup"
declare -x MAIN_CLASS="com.tplink.smb.omada.starter.OmadaLinuxMain"
declare -x PID_FILE="/run/${NAME}.pid"
declare -x JSVC="${JSVC_BIN_PATH:-"$(command -v jsvc 2>/dev/null)"}"
declare -x CURL="${CURL_BIN_PATH:-"$(command -v curl 2>/dev/null)"}"
declare -x MONGOD="${MONGOD_BIN_PATH:-"$(command -v mongod 2>/dev/null)"}"
declare -x PATH="/usr/bin:/usr/sbin:${MONGOD%/*}:${JSVC%/*}:${CURL%/*}"
declare -x OMADA_USER="${OMADA_RUNAS_USER:-root}"
declare -x OMADA_GROUP="$(id -gn "${OMADA_USER}" 2>/dev/null)"
declare -x OMADA_STD_LOG="${OMADA_STD_LOG:-${LOG_DIR}/startup.log}"
declare -x OMADA_ERR_LOG="${OMADA_ERR_LOG:-${LOG_DIR}/startup.log}"
declare -x POLL_HOST="127.0.0.1"
declare -x FQDN_HOST="$(/usr/bin/hostname --fqdn 2>/dev/null)"
declare -x FAIL_MSG="Failed (Exiting) : "
declare -x CORRECT_MSG=""
declare HTTP_PORT_STRING="$(grep "^[^#;]" "${PROPERTY_DIR}/${NAME}.properties" 2>/dev/null | sed -n 's/manage.http.port=\([0-9]\+\)/\1/p' | sed -r 's/\r//')"
declare HTTPS_PORT_STRING="$(grep "^[^#;]" "${PROPERTY_DIR}/${NAME}.properties" 2>/dev/null | sed -n 's/manage.https.port=\([0-9]\+\)/\1/p' | sed -r 's/\r//')"
declare -ix OMADA_UID="0"
declare -ix OMADA_GID="0"
declare -ix HTTP_PORT="${HTTP_PORT_STRING:-8088}"
declare -ix HTTPS_PORT="${HTTPS_PORT_STRING:-8043}"
declare -ax JAVA_OPTS=("-server" "-Xms128m" "-Xmx1024m" "-XX:MaxHeapFreeRatio='60'" "-XX:MinHeapFreeRatio='30'" "-XX:+HeapDumpOnOutOfMemoryError" "-XX:HeapDumpPath='${LOG_DIR}/java_heapdump.hprof'")
declare -ax JSVC_OPTS=()

export JRE_HOME NAME DESC OMADA_HOME LOG_DIR WORK_DIR DATA_DIR PROPERTY_DIR AUTOBACKUP_DIR MAIN_CLASS PID_FILE JSVC CURL MONGOD PATH OMADA_USER OMADA_GROUP OMADA_STD_LOG OMADA_ERR_LOG POLL_HOST FQDN_HOST FAIL_MSG CORRECT_MSG OMADA_UID OMADA_GID HTTP_PORT HTTPS_PORT JAVA_OPTS JSVC_OPTS

#
# Function : Display usage
#

help() {

	>&2 printf "\n%2s%s\033[33m%s\033[0m\n\n" "" "Usage : " "${0##*/} [start|stop|status|help]"
	>&2 printf "%5s%-8s%s\033[32m%s\033[0m\n" "" "start" " : " "- Start the service(s)"
	>&2 printf "%5s%-8s%s\033[32m%s\033[0m\n" "" "stop" " : " "- Stop the service(s)"
	>&2 printf "%5s%-8s%s\033[32m%s\033[0m\n" "" "status" " : " "- Show the status of the service(s)"
	>&2 printf "%5s%-8s%s\033[32m%s\033[0m\n\n" "" "help" " : " "- Show this screen"
	return 1
}

#
# Function : Check script arguments
#

check_args() {

if [[ "${#}" -ne "1" || "${1}" != @(start|stop|status) ]]
then
	help
else
	true
fi
return "${?}"
}

#
# Function : Display informational message
#

print_msg() {

	printf "\n%2s%s\033[33m%s\033[0m%s\n" "" "- You can visit " "'http://${FQDN_HOST}:${HTTP_PORT}'" " to manage the wireless network by HTTP"
	printf "%2s%s\033[33m%s\033[0m%s\n\n" "" "- Or visit " "'https://${FQDN_HOST}:${HTTPS_PORT}'" " to manage the wireless network by HTTPS"
	printf "%2s%s\033[33m%s\033[0m\n" "" "- The Omada SW Controller operational logfile is " "'${LOG_DIR}/server.log'"
	printf "%2s%s\033[33m%s\033[0m\n\n" "" "- The MongoDB database operation logfile is " "'${LOG_DIR}/mongod.log'"
	return 0
}

#
# Function : Check wether effective permissions of current user equal root rights
#

check_effective_perms() {

    if [[ "$(id -u 2>/dev/null)" != "0" ]]
    then
	    >&2 printf "\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "Your effective permissions must equate to root to use this script"
	    return 1
    fi
}

#
# Function : Check if ${OMADA_USER} and ${OMADA_GROUP} exist and determine the corresponding IDs
#

check_omada_owners() {

	declare -i ID_RESULT="0"

	if ! getent group "${OMADA_GROUP}" >/dev/null 2>&1
	then
		ID_RESULT="1"
	else
		if ! getent passwd "${OMADA_USER}" >/dev/null 2>&1
		then
			ID_RESULT="2"
		else
			! OMADA_GID="$(id -g "${OMADA_USER}" 2>/dev/null)" && \
				ID_RESULT="3"
			! OMADA_UID="$(id -u "${OMADA_USER}" 2>/dev/null)" && \
				ID_RESULT="4"
		fi
	fi
	case "${ID_RESULT}" in 1)
		>&2 printf "\n\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "Please create group '${OMADA_GROUP}' first as primary group for a user '${OMADA_USER}'" ;;
			2)
		>&2 printf "\n\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "Please create user '${OMADA_USER}' first with primary group '${OMADA_USER}'" ;;
			3)
		>&2 printf "\n\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "Failed to determine GID of group '${OMADA_GROUP}'" ;;
			4)
		>&2 printf "\n\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "Failed to determine UID of user '${OMADA_USER}'" ;;
			*)
		: ;;
	esac
	return "${ID_RESULT}"
}

#
# Function : Check existence and permissions/ownership of omada directories' ${DATA_DIR}, ${LOG_DIR} and ${WORK_DIR} and attempt to correct when required
#

check_omada_dirs() {

	declare OMADA_DIR=""
	declare DIR_TYPE=""
	declare -i COUNT="0"
	local -a CORRECT_DIRS=()
	local -a FAIL_CREATE_DIRS=()
	local -a FAIL_OWNER_DIRS=()

	for OMADA_DIR in "${DATA_DIR}" "${LOG_DIR}" "${WORK_DIR}"
	do
		while true
		do
			if [[ -d "${OMADA_DIR}" ]]
			then
    				if [[ "${OMADA_UID}" -eq "$(stat "${OMADA_DIR}" -Lc %u 2>/dev/null)" && \
    					"${OMADA_GID}" -eq "$(stat "${OMADA_DIR}" -Lc %g 2>/dev/null)" ]]
				then
					continue 2
				fi
			fi
			CORRECT_DIRS+=("${OMADA_DIR}")
			break
		done
	done
	if [[ "${#CORRECT_DIRS[@]}" -gt "0" ]]
	then
		for OMADA_DIR in "${CORRECT_DIRS[@]}"
		do
			CORRECT_MSG=""
			while true
			do
				if [[ ! -d "${OMADA_DIR}" ]]
				then
					if ! mkdir -m 0755 "${OMADA_DIR}" 2>/dev/null
					then
						FAIL_CREATE_DIRS+=("${OMADA_DIR}")
						continue 2
					fi
					CORRECT_MSG=" Created"
				fi
				! chown -R "${OMADA_USER}:${OMADA_GROUP}" "${OMADA_DIR}" 2>/dev/null && \
					break
				[[ -n "${CORRECT_MSG}" ]] && \
					CORRECT_MSG="${CORRECT_MSG} and"
				echo -n "${CORRECT_MSG} Changed ownership"
				continue 2
			done
			FAIL_OWNER_DIRS+=("${OMADA_DIR}")
		done
	fi
	for DIR_TYPE in CREATE OWNER
	do
		declare -n ACTIVE_DIR_TYPE="FAIL_${DIR_TYPE}_DIRS"
		if [[ "${#ACTIVE_DIR_TYPE[@]}" -gt "0" ]]
		then
			if [[ "${COUNT}" -eq "0" ]]
			then
				>&2 printf "\n\n\033[31m%s\033[0m\n\n" "${FAIL_MSG}"
			fi
			COUNT="$((COUNT+"${#ACTIVE_DIR_TYPE[@]}"))"
			for OMADA_DIR in "${ACTIVE_DIR_TYPE[@]}"
			do
				if [[ "${DIR_TYPE}" == "CREATE" ]]
				then
					>&2 printf "%s\n" " - Could not create '${OMADA_DIR}' with permissions '0755' -> Please correct manually first with \"mkdir -m 0755 '${OMADA_DIR}'\""
				else
					>&2 printf "%s\n" " - Could not set ownership of '${OMADA_DIR}' to '${OMADA_USER}:${OMADA_GROUP}' -> Please correct manually first with \"chown -R '${OMADA_USER}:${OMADA_GROUP}' '${OMADA_DIR}'\""
				fi
			done
		fi
		unset -n ACTIVE_DIR_TYPE
	done
	if [[ "${COUNT}" -gt "0" ]]
	then
		echo ""
	fi
	return "${COUNT}"
}

#
# Function : Handle logfile creation
#

create_log() {

	declare LOG_FILE="${1}"

	if [[ "${#}" -ne "1" ]]
	then
		return 1
	else
		if [[ ! -f "${LOG_FILE}" ]]
		then
			if ! su - "${OMADA_USER}" -c "touch '${LOG_FILE}' 2>/dev/null" 2>/dev/null
			then
				>&2 printf "\n\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "'${LOG_FILE}' creation failed -> Please run \"touch '${LOG_FILE}'\" as user '${OMADA_USER}' first"
				return 1
			fi
		else
			chown "${OMADA_USER}:${OMADA_GROUP}" "${LOG_FILE}"
		fi
		chmod 0600 "${LOG_FILE}"
	fi
	return 0
}

#
# Function : Check presence and permissions for JSVC - for running java apps as services / Curl - for CLI-based HTTP(S) requests / Mongod - Database for Omada SW Controller
#

check_omada_reqs() {

	declare OMADA_REQ=""

	for OMADA_REQ in "${JSVC}:jsvc" "${CURL}:curl" "${MONGOD}:mongod"
	do
		while true
		do
			if [[ -z "${OMADA_REQ%%:*}" ]]
			then
				>&2 printf "\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "'${OMADA_REQ##*:}' not found -> Please install first and/or set the '$(echo -n ${OMADA_REQ##*:} | tr '[:lower:]' '[:upper:]')_BIN_PATH variable in the first section of this script"
			else
				if [[ ! -x "${OMADA_REQ%%:*}" ]]
				then
					>&2 printf "\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "'${OMADA_REQ}' not executable by ${NAME} user '${OMADA_USER}' -> Please run \"chmod u+x '${OMADA_REQ}'\" first"
				else
					break
				fi
			fi
			return 1
		done

 		# check whether JSVC requires -cwd option and complete JSVC options

		if [[ "${OMADA_REQ##*:}" == "jsvc" ]]
		then
			if "${JSVC}" -java-home "${JRE_HOME}" -cwd "/" -help >/dev/null 2>&1
			then
				JSVC_OPTS+=("-cwd" "${OMADA_HOME}/lib")
			fi
			JSVC_OPTS+=("-pidfile" "${PID_FILE}" \
					"-home" "${JRE_HOME}" \
					"-cp" "/usr/share/java/commons-daemon.jar:${OMADA_HOME}/lib/*:${OMADA_HOME}/properties" \
					"-user" "${OMADA_USER}" \
					"-procname" "${NAME}" \
					"-outfile" "${OMADA_STD_LOG}" \
					"-errfile" "${OMADA_ERR_LOG}" \
					"-showversion" \
					"${JAVA_OPTS[@]}")
		fi
	done
	if [[ ! -L "${OMADA_HOME}/bin/mongod" && -x "${MONGOD}" ]]
	then
		if ! ln -fs "${MONGOD}" "${OMADA_HOME}/bin/mongod" >/dev/null 2>&1
		then
			>&2 printf "\n\033[31m%s\033[0m%s\n\n" "${FAIL_MSG}" "'${OMADA_HOME}/bin/mongod' symbolic link creation failed' -> Please run \"ln -fs '${MONGOD}' '${OMADA_HOME}/bin/mongod'\" first"
			return 1
		fi
	fi
	return 0
}

#
# Function : Check if Omada SW Controller is running. Returns 0 for running / 1 for not running
#

is_running() {

	pgrep -f "${MAIN_CLASS}" >/dev/null 2>&1
	return "${?}"
}

#
# Function : Check if Omada SW Controller is functional. Returns 0 for functional / 1 for non-functional / 2 for transitional
#

is_in_service() {

	declare -i RET_CODE="0"

	RET_CODE="$("${CURL}" -I -m 10 -o /dev/null -s -w %{http_code} "http://${FQDN_HOST}:${HTTP_PORT}/actuator/linux/check" 2>/dev/null)"
	case "${RET_CODE}" in 200)
        	return 0 ;;
			0|500)
		return 2 ;;
			*)
		return 1 ;;
	esac
}

#
# Function : Try starting Omada SW Controller
#

start() {

	declare LOG_FILE=""
	declare -i COUNT="0"
	declare -i IN_SERVICE="0"

	for LOG_FILE in "${OMADA_STD_LOG}" "${LOG_DIR}/mongod.log" "${LOG_DIR}/server.log"
	do
		! create_log "${LOG_FILE}" && \
			return 1
	done
	if [[ "${OMADA_STD_LOG}" != "${OMADA_ERR_LOG}" ]]
	then
		! create_log "${OMADA_ERR_LOG}" && \
			return 1
	fi
	printf "\n\033[33m%s\033[0m" "Starting '${DESC}' (Please wait) : "
	if is_running
	then
		if is_in_service >/dev/null 2>&1
		then
			printf "\033[32m%s\033[0m\n\n" "Success"
			printf "%s\n" "'${DESC}' is already running"
			print_msg
		else
			printf "\033[32m%s\033[0m\n\n" "Success"
			printf "%s\n\n" "'${DESC}' is already starting up"
		fi
		return 0
	fi
	printf "\n\n%2s\033[33m%s\033[0m" "" "- Checking ${NAME} user : "
	if [[ "${OMADA_USER}" == "root" ]]
	then
		printf "%s\033[32m%s\033[0m%s\n" "${OMADA_USER} (" "OK" ")"
	else
		printf "%s\033[33m%s\033[0m%s\n\n" "Non-root user (" "Additional checks required" ")"
		printf "%5s\033[35m%s\033[0m" "" "- Checking existence of user and group"
		while true
		do
			if "check_${NAME}_owners"
			then
				printf "%1s%s\033[32m%s\033[0m%s\n" "" "(" "OK" ")"
				printf "%5s\033[35m%s\033[0m" "" "- Checking effective permissions"
				if check_effective_perms
				then
					printf "%1s%s\033[32m%s\033[0m%s\n" "" "(" "OK" ")"
					printf "%5s\033[35m%s\033[0m" "" "- Checking ${NAME} directories"
					if "check_${NAME}_dirs"
					then
						printf "%1s%s\033[32m%s\033[0m%s\n" "" "(" "OK" ")"
						break
					fi
				fi
			fi
			return 1
		done
	fi
	printf "\n%2s\033[33m%s\033[0m" "" "- Polling startup : "
    	"${JSVC}" "${JSVC_OPTS[@]}" "${MAIN_CLASS}" start 2>&1 | tee "${LOG_DIR}/startup.log"
	while true
	do
		is_in_service
		IN_SERVICE="${?}"
		case "${IN_SERVICE}" in 0)
			printf " : \033[32m%s\033[0m\n" "Success"
			print_msg
			return "${IN_SERVICE}" ;;
				1)
			break ;;
				*)
			if [[ "${COUNT}" -gt "300" ]]
			then
				break
			fi
			sleep 1
			echo -n "."
			COUNT="$((COUNT+1))" ;;
		esac
	done
	>&2 printf "\033[31m%s\n\n\033[0m%s\n\n" " ${FAIL_MSG%%:*}" "'${DESC}' start has failed (See logfile '${LOG_DIR}/startup.log')"
	return "${IN_SERVICE}"
}

#
# Function : Try stopping Omada SW Controller
#

stop() {

	declare -i COUNT="0"

	printf "\n\033[33m%s\033[0m" "Stopping '${DESC}' (Please wait) : "
	if ! is_running
	then
		printf "\033[32m%s\033[0m\n" "Success"
		printf "\n%s\n\n" "'${DESC}' was already offline"
		return 0
	fi
    	"${JSVC}" "${JSVC_OPTS[@]}" -stop "${MAIN_CLASS}" 2>&1 | tee "${LOG_DIR}/server.log"
	while true
	do
		if ! is_running
		then
			break
		else
			sleep 1
			COUNT="$((COUNT+1))"
			echo -n "."
			if [[ "${COUNT}" -gt "30" ]]
			then
				break
			fi
		fi
	done
	if ! is_running
	then
		printf "\033[32m%s\033[0m\n" "Success"
		printf "\n%s\n\n" "'${DESC}' has successfully stopped"
	else
		>&2 printf "\033[33m%s\033[0m%s" "Warning : " "'${DESC}' controlled stop has failed (See logfile '${LOGDIR}/server.log') -> Going to kill it"
		if kill "$(cat "${PID_FILE}" 2>/dev/null)" 2>/dev/null
		then
			printf "%1s%s\033[32m%s\033[0m%s\n\n" "" "(" "OK" ")"
		else
			>&2 printf "%1s%s\033[31m%s\033[0m%s\n\n" "" "(" "FAILED" ")"
			false
		fi
	fi
	return "${?}"
}

#
# Function : Check and report on current status of Omada SW Controller
#

status() {

	if is_running
	then
		if is_in_service
		then
			printf "\n\033[33m%s\033[0m\n" "'${DESC}' is running"
			print_msg
		else
			printf "\n\033[33m%s\033[0m\n\n" "'${DESC}' is in a transitional state"
		fi
	else
        	printf "\n\033[33m%s\033[0m%s\n\n" "'${DESC}' is offline"
	fi
	return 0
}

#
# Main code
#

! check_args "${@}" && \
	exit 1
! "check_${NAME}_reqs" && \
	exit 1
"${1}"
exit "${?}"
