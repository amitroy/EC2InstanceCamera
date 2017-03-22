#!/bin/bash

## Variable Declartions ##
# Get Instance Details
instance_id=$(wget -q -O- http://169.254.169.254/latest/meta-data/instance-id)
region=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g')
xenDevicePrefix="xvd"
xenRootDeviceName="xvda"
# Set Logging Optionsc
logfile="/var/log/ebs-snapshot.log"
logfile_max_lines="5000"
# How many days do you wish to retain backups for? Default: 30 days or fetch retention day values from instance's tag.
default_retention_days="30"
tagged_retention_days=$(aws ec2 describe-instances --region $region --instance-ids $instance_id --query 'Reservations[].Instances[].Tags[?Key==`ec2instancecamera:snapshotretention`].Value' --output text)
if [ -z `echo "$tagged_retention_days"` ]
    then
        retention_date_in_seconds=$(date +%s --date "$default_retention_days days ago")
    else
        retention_date_in_seconds=$(date +%s --date "$tagged_retention_days days ago")
fi


## Function Declarations ##
# Function: Setup logfile and redirect stdout/stderr.
log_setup() {
    # Check if logfile exists and is writable.
    ( [ -e "$logfile" ] || touch "$logfile" ) && [ ! -w "$logfile" ] && echo "ERROR: Cannot write to $logfile. Check permissions or sudo access." && exit 1

    tmplog=$(tail -n $logfile_max_lines $logfile 2>/dev/null) && echo "${tmplog}" > $logfile
    exec > >(tee -a $logfile)
    exec 2>&1
}
# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}
# Function: Confirm that the AWS CLI and related tools are installed.
prerequisite_check() {
	for prerequisite in aws wget; do
		hash $prerequisite &> /dev/null
		if [[ $? == 1 ]]; then
			log "In order to use this script, the executable \"$prerequisite\" must be installed." 1>&2; exit 70
		fi
	done
}
# Function: Freeze the disk mountpoints and takes a snapshot of the volume(s) attached to this instance.
freeze_snapshot_volumes() {
	for volume_id in $volume_list; do
		#Variables
        snapshotCompatible=0;
        isFrozen=0;

        #Fetching the EBS ID and EBS device name
        log "Volume ID is $volume_id"
        ebsID=$(echo "$volume_id" | cut -d ',' -f1)
        ebsDV=$(echo "$volume_id" | cut -d ',' -f2)
        
        #Transform EBS Device path from Linux notation to XEN notation
        xenDV=$(echo "$ebsDV" | sed -e "s/\\/sd/\/${xenDevicePrefix}/g")
        
        #Fetch the mountpoint for each ebs volume
        xenDVName=$(echo "$xenDV" | cut -d'/' -f3)
        xenDVMountPoint=$(lsblk -n -d -o NAME,MOUNTPOINT | grep ${xenDVName} | awk '{print $2}'| grep -v '^$')
        
        #LogPrinter
        log "EBS ID: $ebsID"
        log "EBS Device: $ebsDV"
        log "XEN Device: $xenDV"
        #xenMountStatus=$(if [ -z `echo "$xenDVMountPoint"` ]; then echo "Unmounted"; else echo "$xenDVMountPoint"; fi)
        #echo "XEN Device Mount Point: $xenMountStatus"
        
        #Freeze the file system if mounted and skip root device i.e. "/" from being frozen
        if [[ "$xenDVName" == "$xenRootDeviceName"* ]]
        then
            log "Root device encountered. Root devices won't be frozen"
            snapshotCompatible=0;
        elif [ -z `echo "$xenDVMountPoint"` ]
        then
            log "Unmounted Device"
            snapshotCompatible=1;
            isFrozen=0;
        else
            sync
            sudo fsfreeze -f $xenDVMountPoint
            if [ $? -gt 0 ]
            then
                log "Failed freezing filesystem at $xenDVMountPoint" 1>&2
            else
                log "Successfully frozen $xenDVMountPoint" 1>&2
                snapshotCompatible=1;
                isFrozen=1;
            fi
        fi
        
        # Switch case to determine whether to snapshot or not
        case "$snapshotCompatible" in
            1)
            log "Begin snapshot"
            
            # Get the attched device name to add to the description so we can easily tell which volume this is.
            device_name=$(aws ec2 describe-volumes --region $region --output=text --volume-ids $ebsID --query 'Volumes[0].{Devices:Attachments[0].Device}')
            
            # Take a snapshot of the current volume, and capture the resulting snapshot ID
            snapshot_description="$(hostname)-$device_name-backup-$(date +%Y-%m-%d)"
            snapshot_id=$(aws ec2 create-snapshot --region $region --output=text --description $snapshot_description --volume-id $ebsID --query SnapshotId)
            log "New snapshot is $snapshot_id"
            
            # Add a "CreatedBy:EC2InstanceCamera" tag to the resulting snapshot.
            # Why? Because we only want to purge snapshots taken by the script later, and not delete snapshots manually taken.
            aws ec2 create-tags --region $region --resource $snapshot_id --tags Key=CreatedBy,Value=EC2InstanceCamera
            
            #Unfreeze the filesystems
            case "$isFrozen" in
                1)
                    sudo fsfreeze -u $xenDVMountPoint
                    if [ $? -gt 0 ]
                        then
                            log "Failed unfreezing filesystem at $xenDVMountPoint" 1>&2
                        else
                            log "Successful defrost of $xenDVMountPoint" 1>&2
                    fi
                    ;;
                esac
            ;;
        esac
	done
}
# Function: Cleanup all snapshots associated with this instance that are older than $retention_days.
cleanup_snapshots() {
	for volume_id in $volume_list; do
        ebsID=$(echo "$volume_id" | cut -d ',' -f1)
        ebsDV=$(echo "$volume_id" | cut -d ',' -f2)
		snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters "Name=volume-id,Values=$ebsID" "Name=tag:CreatedBy,Values=EC2EInstanceCamera" --query Snapshots[].SnapshotId)
        log "Checking snapshots for volume: $ebsID"
        log "Snapshots created before: $(date -d @$retention_date_in_seconds) will be deleted"
        
        for snapshot in $snapshot_list; do
            log "Checking $snapshot..."
			
            # Check age of snapshot
			snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
			snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
			snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description)
            
            #Click the snapshot
			if (( $snapshot_date_in_seconds <= $retention_date_in_seconds )); then
				log "DELETING snapshot $snapshot. Description: $snapshot_description ..."
				aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
			else
				log "Not deleting snapshot $snapshot. Description: $snapshot_description ..."
			fi
		done
	done    
}

## SCRIPT COMMANDS ##
log_setup
prerequisite_check
# Grab all volume IDs attached to this instance
volume_list=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instance_id --query 'Volumes[].Attachments[].{ID:VolumeId,MP:Device}' --output text | sed -e 's/\s\+/,/g')
freeze_snapshot_volumes
cleanup_snapshots
