#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin

###############################################################################
# Core - please do not modify!                                                #
###############################################################################

VERSION="0.0.1-alpha"

OPTS=`getopt -o vhc:d: --long verbose,dry-run,version,help,,mysql-only,files-only,config:,dbs:,databases: -n 'parse-options' -- "$@"`

eval set -- "$OPTS"
VERBOSE=false
DRY_RUN=false
CONFIG=false
MYSQL_ONLY=
MYSQL_DATABASES=
FILES_ONLY=
FTP_ERROR=false
S3_ERROR=false
MYSQL_ERROR=false
PGSQL_ERROR=false
FILES_BACKUP_ERROR=0
BACKUP_PID=$$

if [ $? != 0 ]; then 
    echo "Failed parsing options." >&2
    exit 1
fi

display_help() {
    echo "Usage: $0 [option...] {--help|--config|--mysql-only|--files-only|--databases, --dbs|--dry-run|--verbose|--version}" >&2
    echo
    echo "   -h, --help              Display this help message. (don't shit sherlock :o)"
    echo "   -v, --verbose           Run in verbose mode (for debug purposes), it means that he will put output to screen and log file."
    echo "                           It work in silent mode by default which means that it only logs output into the log file."
    echo "   -c, --config            Set default path where config file is located."
    echo
    echo "   --mysql-only            Backing databases only."
    echo "   --files-only            Backing files only."
    echo "   -d, --databases, --dbs  Select databases to backing up."
    echo
    echo "   --dry-run               Testing process where the effects of a possible failure are intentionally mitigated. (Not work yet)"
    echo "   --version               Display current version of script and ask developer if it is possible to update."
    echo
}

display_version() {
    echo "Version: $VERSION"
}

while true; do
    case "$1" in
    	--config  | -c ) CONFIG=$2; shift 2 ;;
        --verbose | -v ) VERBOSE=true; shift ;;
        --help    | -h ) display_help; exit 0 ;;
        --dry-run ) DRY_RUN=true; shift ;;
        --version ) display_version; exit 0;;
	--mysql-only ) MYSQL_ONLY=true; shift ;;
        --dbs | --databases | -d ) MYSQL_DATABASES=$2; shift 2 ;;
        --files-only ) FILES_ONLY=true; shift ;;
        -- ) shift; break ;;
    esac
done

if [ $CONFIG == "false"  ]; then
	CONFIG="./backup.conf"
fi

if [ -f $CONFIG ]; then
	. $CONFIG
else
	echo -n "Config file $CONFIG not found! "
	if [ $DRY_RUN == "true" ]; then
		echo -n  "This is so important that I can not even initiate dry-run. "
	fi
	echo "Exiting."
	exit 1
fi


log() {
    if [ -n "$1" ] && [ -n "$2" ]; then
        local survey=$1
        local message=$2
    else
        local message=$@
    fi
    
    if [ $VERBOSE == "true" ]; then
        if [ -n "$survey" ]; then
            case $survey in
                "ERR" | "FAIL" | "ERROR" | "CRITICAL" ) local survey_c="\e[31m$survey\e[0m" ;;
                "INFO" ) local survey_c="\e[93m$survey\e[0m" ;;
                "OK" ) local survey_c="\e[32m$survey\e[0m" ;;
                * ) local survey_c=$survey ;;
            esac
            echo -ne "[ $survey_c ] "
        fi
        echo "`date "+%Y-%m-%d %H:%M:%S"`: $message"
    fi

    if [ -n "$survey" ]; then
        echo -n "[ $survey ] " >> "$log_file"
    fi
    echo "`date "+%Y-%m-%d %H:%M:%S"`: $message" >> "$log_file"
}

send_email() {
    local message="$1"
    if [ "$message" = "" ]; then
        $message="Backup error has occured, but no error was provided. Please check."
    fi

    (
        echo "From: $mail_from";
        echo "To: $mail_to";
        echo "Subject: $mail_subject";
        echo;echo -e "$message";
    ) | sendmail -t
    ec=$?

    if [ $ec -eq 0 ]; then
        log "OK" "Email sent successfully."
    else
        log "ERROR" 'Error sending email!'" Sendmail returned $ec"
    fi
}

kill_process_tree() {
    if [ -z "$1" ]; then
        return 1
    fi
    local pid_to_kill=$1
    "$KILL" -TSTP $pid_to_kill
    ps --ppid $pid_to_kill --no-headers -o pid | while read proc_pid; do
        kill_process_tree $proc_pid
    done
    "$KILL" $pid_to_kill
    "$KILL" -CONT $pid_to_kill
}

check_free_space() {
    local checker_pid=$BASHPID
    local space_limit_kb=$(($free_space_limit_mb*1024))
    while [ -f $run_file ]; do
        local free_space=`df -P $backup_dir | tail -n 1 | awk '{print $4}'`
        if [ "$free_space" -le "$space_limit_kb" ]; then
            local message="Backup was terminated, because disk space limit was reached. Free space left: $free_space KB"
            log "CRITICAL" "$message"
            send_email "$message"
            "$KILL" -TSTP $BACKUP_PID
            ps --ppid $BACKUP_PID --no-headers -o pid | grep -v $checker_pid | while read proc_pid; do
                kill_process_tree $proc_pid
            done
            sleep 5
            "$KILL" $BACKUP_PID
            "$KILL" -CONT $BACKUP_PID
             cleanup
            exit
        fi
        sleep 1
    done
}

cleanup() {
    log "INFO" "Cleaning up..."
    rm -f "$run_file"
}

control_c() {
    cleanup
    exit 1
}

###############################################################################
# Setup - please do not modify this block too!                                #
###############################################################################

SENDMAIL=`which sendmail`
KILL=`which kill`
validation_errors=`echo`

# catch CTRL+C
trap control_c INT

if [ ! -d "$backup_dir" ]; then
    mkdir -p "$backup_dir"
    if [ ! -d "$backup_dir" ]; then
        send_email "Couldn't create backup directory"'!'" Exiting. Please check it manually."
        cleanup
        exit 1
    fi
fi

touch "$log_file"
if [ ! -f "$log_file" ]; then
    send_email "Could not create log file: $log_file"'!'" Exiting. Please check it manually."
    cleanup
    exit 1
fi

if [ -z "$SENDMAIL" ]; then
    log "CRITICAL" "sendmail not found! It's required to send emails about problems. Please install it. Backup will exit now."
    cleanup
    exit 1
fi

if [ "$files_backup" -eq 1 ]; then
    TAR=`which tar`
    if [ -z "$TAR" ]; then
        validation_errors="`echo $validation_errors\ntar command not found.`"
    fi
fi

if [ "$mysql_compression" -eq 1 ] || [ "$pgsql_compression" -eq 1 ] || [ "$files_backup" -eq 1 ]; then
    GZIP=`which gzip`
    if [ -z "GZIP" ]; then
        validation_errors="`echo $validation_errors\ngzip command not found.`"
    fi
fi

if [ "$ftp_enabled" -eq 1 ]; then
    LFTP=`which lftp`
    if [ -z "$LFTP" ]; then
        validation_errors="`echo $validation_errors\nkill command not found.`"
    fi
fi

#if [ "$s3_enabled" -eq 1 ]; then 
#fi

if [ "$mysql_backup" -eq 1 ]; then
    MYSQL=`which mysql`
    MYSQLDUMP=`which mysqldump`
    if [ -z "$MYSQL" ]; then
        validation_errors="`echo $validation_errors\nmysql command not found.`"
    fi
    if [ -z "$MYSQLDUMP" ]; then
        validation_errors="`echo $validation_errors\nmysqldump command not found.`"
    fi
fi

#if [ "$pgsql_backup" -eq 1 ]; then
#    PGSQL=`which psql`
#    PGSQLDUMP=`which pg_dump`
#    if [ -z "$PGSQL" ]; then
#        validation_errors="`echo $validation_errors\npsql command not found.`"
#    fi
#    if [ -z "$PGSQLDUMP" ]; then
#        validation_errors="`echo $validation_errors\npg_dump command not found.`"
#    fi
#fi

if [ -n "$validation_errors" ]; then
    log "CRITICAL" "Configuration verification error! Please check configuration and restart backup.\n\nProblems found:$validation_errors"
    send_email "Configuration verification error! Please check configuration and restart backup.\n\nProblems found:$validation_errors"
    cleanup
    exit 1
fi

if [ -f "$run_file" ]; then
    log "CRITICAL" "Previous backup is still running or stale pid file $run_file exist. Please check it manually. Exiting."
    send_email "Previous backup is still running or stale pid file $run_file exist. Please check it manually. Exiting."
    exit 1
fi

log "Backup started."

if [ "$ftp_enabled" -eq 1 ]; then
    log "INFO" "Preparing directory for backup on FTP server..."
    "$LFTP" -u $ftp_user,$ftp_password -e "set ftp:ssl-allow off; set ftp:use-size false;mkdir -p /$ftp_remote_dir/$run_date;quit" $ftp_server
    if [ $? -ne 0 ]; then
        log "ERROR" 'Failed to create backup folder on FTP server!'
        ftp_error=1
    else
        log "OK" "FTP directory prepared."
    fi
fi

echo "$BACKUP_PID" > "$run_file"
if [ ! -f "$run_file" ]; then
    log "CRITICAL" "Could not create PID file: $run_file Please check it manually. Exiting."
    send_email "Could not create PID file: $run_file Please check it manually. Exiting."
    cleanup
    exit 1
fi

check_free_space &

###############################################################################
# Others stuff and helpers                                                    #
###############################################################################

# Prehooks (running before main backup)
if [ -f "/root/skrypty/backup.pre" ]; then
    . "/root/skrypty/backup.pre"
fi

# Variables from script parameters overwrite main configucation 
if [ "$MYSQL_ONLY" == "true" ]; then
    mysql_backup=1
    #$files_backup=0
fi

if [ "$FILES_ONLY" == "true" ]; then
    mysql_backup=0
    #$files_backup=0
fi

###############################################################################
# Main Functionality - Backup MySQL                                           #
###############################################################################

if [ "$mysql_backup" -eq 1 ]; then
    log "INFO" "Backing up MySQL databases..."
    mkdir "$mysql_backup_dir"
    if [ -d "$mysql_backup_dir" ]; then
        if [ "$ftp_enabled" -eq 1 ]; then
            if [ "$FTP_ERROR" == "false" ]; then
                "$LFTP" -u $ftp_user,$ftp_password -e "set ftp:ssl-allow off; set ftp:use-size false;mkdir /$ftp_remote_dir/$run_date/mysql;quit" "$ftp_server"
                if [ $? -ne 0 ]; then
                    log "ERROR" 'Failed to create backup folder for MySQL databases on ftp server! MySQL databases will not be sent to FTP server.'
                    ftp_error=1
                fi
            else
                log "ERROR" "MySQL databases will not be sent to FTP server because of previous FTP errors."
            fi
        fi
        failed_dbs=`echo`
        if [ -n "$MYSQL_DATABASES" ]; then
            databases="$MYSQL_DATABASES"
        elif [ -n "$mysql_databases" ]; then
            databases="$mysql_databases"
        else
            databases=`$MYSQL -u "$mysql_user" -p"$mysql_password" --skip-column-names -e "SHOW DATABASES;" | grep -v -P "(performance_schema|information_schema)"`
        fi
        if [ "$?" -ne 0 ]; then
            log "ERROR" "Failed to fetch databases!"
            MYSQL_ERROR=1
            num_databases=0
            databases=
        else
            num_databases=`echo "$databases" | wc -l`
        fi
        counter=0
        skipped=0

        if [ -n "$MYSQL_DATABASES" ] || [ -n "$mysql_databases" ]; then
	    dbases=`$MYSQL -u "$mysql_user" -p"$mysql_password" --skip-column-names -e "SHOW DATABASES;" | grep -v -P "(performance_schema|information_schema)"`
            dbases_count=`echo "$dbases" | wc -l`
	    skipped=$(($dbases_count-$num_databases))
        fi

        for db in $databases
        do
            if [ "$( echo "$db" | grep -E "$mysql_database_exceptions")" == "" ] || ([ -n "$mysql_databases" ] || [ -n "$MYSQL_DATABASES" ]); then
                db_backing_start=$(date +%s)
                log "INFO" "Dumping database $db..."
                db_backup_file="$mysql_backup_dir/$db-${run_date}_`date +'%T'`.sql"
                $MYSQLDUMP -E -R -u "$mysql_user" -p"$mysql_password" --single-transaction --databases "$db" > "$db_backup_file"
		db_dump_size=`du -hs $db_backup_file | awk '{print $1}'`
                if [ "$?" -ne 0 ]; then
                    log "ERROR" "Failed to backup database $db"'!'
                    failed_dbs="$failed_dbs `echo -e "\n$db"`"
                    MYSQL_ERROR=1
                else
                    if [ "$mysql_compression" -eq 1 ]; then
                        $GZIP "$db_backup_file"
                        if [ "$?" -ne 0 ]; then
                            log "ERROR" "Gzip compression error. Contining with uncompressed backup."
                            MYSQL_ERROR=1
                        else
                            db_backup_file="$db_backup_file.gz"
                            db_dump_size=`du -hs $db_backup_file | awk '{print $1}'`
                        fi
                    fi
                    db_backing_end=$(date +%s)
                    db_backing_time=$(( $db_backing_end - $db_backing_start ))
                    log "OK" "Database $db backed up successfully which size $db_dump_size in time $(($db_backing_time / 3600))hours $((($db_backing_time / 60) % 60))min $(($db_backing_time % 60))sec."
                    ((counter++))
                    if [ "$ftp_enabled" -eq 1 ] && [ "$FTP_ERROR" == "false" ]; then
                        db_transport_start=$(date +%s)
                        "$LFTP" -u $ftp_user,$ftp_password -e "set ftp:ssl-allow off; set ftp:use-size false;cd /$ftp_remote_dir/$run_date/mysql;put $db_backup_file;quit" "$ftp_server"
                        if [ "$?" -ne 0 ]; then
                            log "ERROR" "Failed to send database $db to FTP server"'!'
                            FTP_ERROR=1
                        else
			    db_transport_end=$(date +%s)
                            db_transport_time=$(( $db_transport_end - $db_transport_start  ))
                            log "OK" "Database $db which size $db_dump_size sent to FTP server successfully in time $(($db_transport_time / 3600))hours $((($db_transport_time / 60) % 60))min $(($db_transport_time % 60))sec."
                        fi
                    fi
                    if [ "$s3_enabled" -eq 1 ]; then
                        db_transport_start=$(date +%s)
                        "$S3CMD" put "$db_backup_file" "$s3_path/$run_date/mysql/"
                        if [ "$?" -eq 0 ]; then
                            db_transport_end=$(date +%s)
                            db_transport_time=$(( $db_transport_end - $db_transport_start  ))
                            log "OK" "Database $db which size $db_dump_size sent to S3 successfully in time $(($db_transport_time / 3600))hours $((($db_transport_time / 60) % 60))min $(($db_transport_time % 60))sec."
                        else
                            S3_ERROR=1
                            log "ERROR" "Failed to send database $db to S3"'!'
                        fi
                    fi
                    if [ "$delete_after_copy" -eq 1 ] && [ "$FTP_ERROR" == "false" ] && [ "$S3_ERROR" == "false" ]; then
                        if [ "$ftp_enabled" -eq 1 ] || [ "$s3_enabled" -eq 1 ]; then
                            log "INFO" "Removing local file $db_backup_file..."
                            rm -f "$db_backup_file"
                        else
                            log "INFO" "delete_after_copy option is enabled, but neither FTP nor S3 backup was enabled. Ignoring."
                        fi
                    fi
                fi
            else
                log "INFO" "Skipping database $db because is in exceptions."
                ((skipped++))
            fi
        done
        if [ -n "$failed_dbs" ]; then
            log "ERROR" "Backup of following databases has failed: $failed_dbs"
            log "INFO" "You need to verify that manually."
        fi
        if [ "$MYSQL_ERROR" == "false" ]; then
            log "OK" "Backed up $counter/$num_databases MySQL databases  (Skipped by exceptions: $skipped database(s))."
        else
            log "CRITICAL" "Error occured during MySQL backup"'!'
        fi
    else
        log "CRITICAL" "Could not create directory $mysql_backup_dir"'!'" MySQL backup will not run."
        MYSQL_ERROR=1
    fi
fi

###############################################################################
# Main Functionality - Files Backup                                           #
###############################################################################

if [ "$files_backup" -eq 1 ]; then
    log "INFO" "Backing up files..."
    mkdir "$files_backup_dir"
    if [ -d "$files_backup_dir" ]; then
        if [ "$ftp_enabled" -eq 1 ]; then
            if [ "$FTP_ERROR" == "false" ]; then
                "$LFTP" -u $ftp_user,$ftp_password -e "set ftp:ssl-allow off; set ftp:use-size false;mkdir /$ftp_remote_dir/$run_date/files;quit" "$ftp_server"
                if [ "$?" -ne 0 ]; then
                    log "ERROR" 'Failed to create backup folder for files on ftp server! Files will not be sent to FTP server.'
                    FTP_ERROR=1
                fi
            else
                log "INFO" "Files will not be sent to FTP server because of previous FTP errors."
            fi
        fi
        cat "$files_config" | while read dir name params excludes
        do
            stepbystep=false
            classic=true
            if [  -n "$params" ]; then
                for param in $(echo $params | sed "s/,/ /g")
                do
                    case $param in
                        sbs ) stepbystep=true; classic=false ;;
                        wholecompress ) wholecompress=true ;;
                        onlylocal ) onlylocal=true ;;
                        dontdelete ) donotdelete=true ;;
                    esac
                done
            fi

            # Step by step (directory by directory) files backup method
            # It's better to backups user's home directories one by one.
            if [ "$stepbystep" == "true"  ]; then
                if [ -n "$dir" ]; then
                    mkdir "$files_backup_dir/$name"
                    if [ -d "$files_backup_dir/$name" ]; then
                        if [ "$ftp_enabled" -eq 1 ] && [ -z "$onlylocal" ]; then
                            if [ "$FTP_ERROR" == "false" ]; then
                                "$LFTP" -u $ftp_user,$ftp_password -e "set ftp:ssl-allow off; set ftp:use-size false;mkdir /$ftp_remote_dir/$run_date/files/$name;quit" "$ftp_server"
                                if [ "$?" -ne 0 ]; then
                                    log "ERROR" 'Failed to create backup folder for files on ftp server! Files will not be sent to FTP server.'
                                    FTP_ERROR=1
                                fi
                            else
                                log "ERROR" "Files will not be sent to FTP server because of previous FTP errors."
                            fi
                        fi
                    else
                        log "CRITICAL" "Could not create directory $files_backup_dir/$name"'!'" Skips to next directory..."
                        continue
                    fi
                    directories_tree=`find $dir -mindepth 1 -maxdepth 1 -type d -print`
                    for directory in $directories_tree
                    do
                        directory_path=`echo $directory | awk '{print substr($1,2);}'`
                        directory_name=`echo $directory | awk -F/ '{print $NF}'`
                        log "INFO" "Creating backup of directory: $directory"
                        "$TAR" -czf "$files_backup_dir/$name/$directory_name.tar.gz" -C / $directory_path
                        rc=$?
                        if [ $rc -gt 1 ]; then
                            log "ERROR" "Error during creation of archive: $directory_name.tar.gz"'!'
                            FILES_BACKUP_ERROR=1
                        else
                            if [ $rc -eq 1 ]; then
                                log "INFO" "Warning: some files were changed while creating archive $directory_name.tar.gz"
                            fi
                            log "OK" "Backup of directory $directory created successfully."
                            if [ "$ftp_enabled" -eq 1 ] && [ "$FTP_ERROR" == "false" ] && [ -z "$onlylocal" ] ; then
                                "$LFTP" -u $ftp_user,$ftp_password -e "set ftp:ssl-allow off; set ftp:use-size false;cd /$ftp_remote_dir/$run_date/files/$name;put $files_backup_dir/$name/$directory_name.tar.gz;quit" "$ftp_server"
                                if [ $? -ne 0 ]; then
                                    log "ERROR" "Failed to send file $files_backup_dir/$name/$directory_name.tar.gz to ftp server"'!'
                                    FTP_ERROR=1
                                else
                                    log "OK" "Backup file $files_backup_dir/$name/$directory_name.tar.gz successfully sent to ftp server."
                                fi
                            fi
                            if [ "$s3_enabled" -eq 1 ] && [ -z "$onlylocal" ]; then
                                "$S3CMD" put "$files_backup_dir/$name/$directory_name.tar.gz" "$s3_path/$run_date/files/"
                                if [ "$?" -eq 0 ]; then
                                    log "OK" "File $name.tar.gz sent to S3 successfully."
                                else
                                    log "ERROR" "Failed to send $name.tar.gz file to S3"'!'
                                    S3_ERROR=1
                                fi
                            fi
                            
                            if [ "$delete_after_copy" -eq 1 ] && [ -z "$onlylocal" ] && [ -z "$donotdelete" ] && [ "$FTP_ERROR" == "false" ] && [ "$S3_ERROR" == "false" ]; then
                                if [ "$ftp_enabled" -eq 1 ] || [ "$s3_enabled" -eq 1 ]; then
                                    log "OK" "Removing local file $files_backup_dir/$name/$directory_name.tar.gz..."
                                    rm -f "$files_backup_dir/$name/$directory_name.tar.gz"
                                else
                                    log "INFO" "delete_after_copy option is enabled, but neither FTP nor S3 backup was enabled. Ignoring."
                                fi
                            fi

                            if [ -n "$onlylocal" ] && [ -z "$donotdelete" ]; then
                                log "INFO" "Backup of $name has been marked as a local only. It is not transferred anywhere."
                            fi
                            
                            if [ -n "$donotdelete" ]; then
                                log "INFO" "Backup of $name is not to be removed, it is intact locally."
                            fi
                        fi
                    done
                else
                    log "ERROR" "Directory $dir does not exist, skips to next directory..."
                    continue
                fi
            fi

            # Default files backup method
            if [ "$classic" == "true" ]; then
                if [ -n "$dir" ]; then
                    log "OK" "Creating backup of directory: $dir"
                    "$TAR" -czf "$files_backup_dir/$name.tar.gz" $excludes $dir
                    rc=$?
                else
                    log "INFO" "Directory $dir not exists, continue to next directory..."
                    continue
                fi
                if [ $rc -gt 1 ]; then
                    log "ERROR" "Error during creation of archive: $name.tar.gz"'!'
                    FILES_ERROR=1
                else
                    if [ $rc -eq 1 ]; then
                        log "INFO" "Warning: some files were changed while creating archive $name.tar.gz."
                    fi
                    log "OK" "Backup of directory $dir created successfully."
                    if [ "$ftp_enabled" -eq 1 ] && [ "$FTP_ERROR" == "false" ] && [ -z "$onlylocal" ]; then
                        "$LFTP" -u $ftp_user,$ftp_password -e "set ftp:ssl-allow off; set ftp:use-size false;cd /$ftp_remote_dir/$run_date/files;put $files_backup_dir/$name.tar.gz;quit" "$ftp_server"
                        if [ $? -ne 0 ]; then
                            log "ERROR" "Failed to send file $files_backup_dir/$name.tar.gz to ftp server"'!'
                            FTP_ERROR=1
                        else
                            log "OK" "Backup file $files_backup_dir/$name.tar.gz successfully sent to ftp server."
                        fi
                    fi
                    if [ "$s3_enabled" -eq 1 ] && [ -z "$onlylocal" ]; then
                        "$S3CMD" put "$files_backup_dir/$name.tar.gz" "$s3_path/$run_date/files/"
                        if [ "$?" -eq 0 ]; then
                            log "OK" "File $name.tar.gz sent to S3 successfully."
                        else
                            log "ERROR" "Failed to send $name.tar.gz file to S3"'!'
                            S3_ERROR=1
                        fi
                    fi

                    if [ "$delete_after_copy" -eq 1 ] && [ -z "$onlylocal" ] && [ -z "$donotdelete" ] && [ "$FTP_ERROR" == "false" ] && [ "$S3_ERROR" == "false" ]; then
                        if [ "$ftp_enabled" -eq 1 ] || [ "$s3_enabled" -eq 1 ]; then
                            log "OK" "Removing local file $files_backup_dir/$name.tar.gz..."
                            rm -f "$files_backup_dir/$name.tar.gz"
                        else
                            log "INFO" "delete_after_copy option is enabled, but neither FTP nor S3 backup was enabled. Ignoring."
                        fi
                    fi

                    if [ -n "$onlylocal" ] && [ -z "$donotdelete" ]; then
                        log "INFO" "Backup of $name has been marked as a local only. It is not transferred anywhere."
                    fi

                    if [ -n "$donotdelete" ]; then
                        log "INFO" "Backup of $name is not to be removed, it is intact locally."
                    fi
                fi
            fi
        done
    else
        log "CRITICAL" "Could not create directory $files_backup_dir"'!'" Backup all files will not run."
        FILES_ERROR=1
    fi
fi






#########################################################

if [ "$FTP_ERROR" != false ] || [ "$MYSQL_ERROR" != "false" ] || [ "$S3_ERROR" != "false" ]; then
    full_log=`cat $log_file`
    mail_subject="Backup on `hostname` has been finished with errors."
    mail_body="Full log below:\n\n$full_log"
    send_email "$mail_body"
else
    if [ "$send_backup_report" -eq 1 ]; then
        full_log=`cat $log_file`
        mail_subject="Backup report from `hostname` - OK"
	mail_body="Backup was finished successfully!\nFull log below:\n\n$full_log"
        send_email "$mail_body"
        log "INFO" "Sending backup report."
    fi
fi

cleanup
