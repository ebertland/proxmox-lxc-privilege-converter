#!/bin/bash

# print banner
banner() {
    clear
    cat << "EOF"
______________   _______________         .____     ____  ____________  
\______   \   \ /   /\_   _____/         |    |    \   \/  /\_   ___ \ 
 |     ___/\   Y   /  |    __)_   ______ |    |     \     / /    \  \/ 
 |    |     \     /   |        \ /_____/ |    |___  /     \ \     \____
 |____|      \___/   /_______  /         |_______ \/___/\  \ \______  /
                             \/                  \/      \_/        \/ 
                      .__      .__.__                                  
         _____________|__|__  _|__|  |   ____   ____   ____            
         \____ \_  __ \  \  \/ /  |  | _/ __ \ / ___\_/ __ \           
         |  |_> >  | \/  |\   /|  |  |_\  ___// /_/  >  ___/           
         |   __/|__|  |__| \_/ |__|____/\___  >___  / \___  >          
         |__|                               \/_____/      \/           
                                             __                        
       ____  ____   _______  __ ____________/  |_  ___________         
     _/ ___\/  _ \ /    \  \/ // __ \_  __ \   __\/ __ \_  __ \        
     \  \__(  <_> )   |  \   /\  ___/|  | \/|  | \  ___/|  | \/        
      \___  >____/|___|  /\_/  \___  >__|   |__|  \___  >__|           
          \/           \/          \/                 \/       v1.0   
           From unprivileged to privileged and vice versa
          Using vzdump backup / restore to rewrite metadata
         Will use snapshot method. Ensure taking snaps works.
    Assuming you have enough free space in images and target storage.
EOF
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi
}

# list and select LXC containers
select_container() {
    echo -e "\n\nChoose a Container to convert:\n"
    IFS=$'\n'
    lxc_list=$(pct list | awk '{if(NR>1)print $1 " " $3}')
    select opt in $lxc_list; do
        if [ -n "$opt" ]; then
            CONTAINER_ID=$(echo "$opt" | awk '{print $1}')
            CONTAINER_NAME=$(echo "$opt" | awk '{print $2}')
            echo -e "Selected container: $CONTAINER_ID ($CONTAINER_NAME)\n"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
}

# select backup storage
select_backup_storage() {
    echo -e "Select backup storage (this is just for the tmp-file we create LXC from):"
    backup_storages=$(pvesm status --content backup | awk '{if(NR>1)print $1}')
    select opt in $backup_storages; do
        if [ -n "$opt" ]; then
            BACKUP_STORAGE=$opt
            echo -e "Selected backup storage: $BACKUP_STORAGE"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
}

# perform backup
backup_container() {
    echo -e "Performing backup of container $CONTAINER_ID...\n"
    vzdump_output=$(mktemp)
    vzdump "$CONTAINER_ID" --compress zstd --storage "$BACKUP_STORAGE" --mode snapshot | tee "$vzdump_output"
    BACKUP_PATH=$(awk '/tar.zst/ {print $NF}' "$vzdump_output" | tr -d "'")
    rm "$vzdump_output"

    if [ -z "$BACKUP_PATH" ]; then
        echo "Backup of container $CONTAINER_ID failed"
        exit 1
    fi
    echo -e "Backup of container $CONTAINER_ID successful\n"
}

# select target storage for the new container
select_target_storage() {
    echo -e "Select target storage for the new container:\n"
    target_storages=$(pvesm status --content images | awk '{if(NR>1)print $1}')
    select opt in $target_storages; do
        if [ -n "$opt" ]; then
            TARGET_STORAGE=$opt
            echo -e "Selected target storage: $TARGET_STORAGE\n"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
}

# find the next free ID
find_next_free_id() {
    local existing_ids
    existing_ids=$({ pct list | awk 'NR>1 {print $1}'; qm list | awk 'NR>1 {print $1}'; } | sort -un)

    local id=100
    while true; do
        if ! grep -q "^$id$" <<< "$existing_ids"; then
            echo "$id"
            break
        fi
        ((id++))
    done
}

# perform conversion
perform_conversion() {
    if pct config "$CONTAINER_ID" | grep -q 'unprivileged: 1'; then
        UNPRIVILEGED_FLAG=true
        echo "Container $CONTAINER_ID is currently unprivileged."
    else
        UNPRIVILEGED_FLAG=false
        echo "Container $CONTAINER_ID is currently privileged."
    fi

    NEW_CONTAINER_ID=$(find_next_free_id)

    if $UNPRIVILEGED_FLAG; then
        echo -e "Converting unprivileged container $CONTAINER_ID to privileged container $NEW_CONTAINER_ID...\n"
        if ! pct restore "$NEW_CONTAINER_ID" "$BACKUP_PATH" --storage "$TARGET_STORAGE" --unprivileged false -ignore-unpack-errors 1; then
            echo "Conversion to container $NEW_CONTAINER_ID failed"
            exit 1
        fi
    else
        echo -e "Converting privileged container $CONTAINER_ID to unprivileged container $NEW_CONTAINER_ID...\n"
        if ! pct restore "$NEW_CONTAINER_ID" "$BACKUP_PATH" --storage "$TARGET_STORAGE" --unprivileged -ignore-unpack-errors 1; then
            echo "Conversion to container $NEW_CONTAINER_ID failed"
            exit 1
        fi
    fi
    echo -e "\nConversion to container $NEW_CONTAINER_ID successful\n"
}

# manage LXC states
manage_lxc_states() {
    read -r -p "Shutdown source and start target container? [Y/n]: " user_choice
    user_choice=${user_choice:-Y}

    if [[ $user_choice =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "Please note: If the container does not shut down within 3 minutes, a forced termination will be initiated."
        pct shutdown "$CONTAINER_ID"
        local counter=0
        local timeout=180

        while [ $counter -lt $timeout ]; do
            if ! pct status "$CONTAINER_ID" | grep -q "running"; then
                echo -e "Container $CONTAINER_ID shutdown successful"
                break
            fi
            sleep 5
            ((counter+=5))
        done

        if [ $counter -ge $timeout ]; then
            echo -e "Container $CONTAINER_ID did not shut down as expected, initiating forced termination.\n"
            if ! pkill -9 -f "lxc-start -F -n $CONTAINER_ID"; then
                echo -e "Failed to force shutdown container $CONTAINER_ID\n"
                exit 1
            fi
        fi

        if ! pct start "$NEW_CONTAINER_ID"; then
            echo -e "Failed to start container $NEW_CONTAINER_ID\n"
            exit 1
        fi
        echo -e "Container $NEW_CONTAINER_ID started successfully\n"
    else
        echo -e "Skipping shutdown of source and start of target container.\n"
    fi
}

# ask for cleanup of temporary backup files
cleanup_temp_files() {
    read -r -p "Do you want to clean up temporary backup files? "$BACKUP_PATH" [Y/n]: " cleanup_choice
    cleanup_choice=${cleanup_choice:-Y}

    if [[ $cleanup_choice =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "Cleaning up temporary backup files..."
        if rm -f "$BACKUP_PATH"; then
            echo "Temporary backup files cleaned up successfully."
        else
            echo "Failed to clean up temporary backup files."
        fi
    else
        echo "Skipping cleanup of temporary backup files."
    fi
    echo
}

main_menu() {
    banner
    check_root
    select_container
    select_backup_storage
    backup_container
    select_target_storage
    perform_conversion
    manage_lxc_states
    cleanup_temp_files
}

# Main script execution
main_menu