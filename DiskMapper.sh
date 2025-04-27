#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# List all disk devices with full paths
disks=($(lsblk -d -p -o NAME,TYPE -n | grep ' disk$' | awk '{print $1}'))

# List all partitions
partitions=($(lsblk -p -o NAME,TYPE -n | grep ' part$' | awk '{print $1}'))

# Find disks with no partitions
no_part_disks=()
for disk in "${disks[@]}"; do
    has_part=false
    for part in "${partitions[@]}"; do
        if [[ $part == ${disk}[0-9]* ]]; then
            has_part=true
            break
        fi
    done
    if ! $has_part; then
        no_part_disks+=("$disk")
    fi
done

# List unmounted partitions with details
unmounted_parts=()
index=1
while read -r name size fstype mountpoint; do
    if [ -z "$mountpoint" ] && [ -n "$fstype" ]; then
        unmounted_parts[$index]="$name"
        echo "$index. $name $size $fstype"
        ((index++))
    fi
done < <(lsblk -p -o NAME,SIZE,FSTYPE,MOUNTPOINT -n | grep -v ' disk$')

# List disks that need partitioning
if [ ${#no_part_disks[@]} -gt 0 ]; then
    echo -e "\nNote: The following drives need partitioning and formatting before they can be mounted:"
    for disk in "${no_part_disks[@]}"; do
        size=$(lsblk -d -o SIZE -n "$disk" 2>/dev/null || echo "unknown")
        echo "- $disk $size"
    done
fi

# Check if root is on LVM with free space
root_dev=$(findmnt -n -o SOURCE /)
reclaim_available=false
if [[ $root_dev == /dev/mapper/* ]]; then
    lv_path=$root_dev
    vg_name=$(lvs --noheadings -o vg_name $lv_path | tr -d ' ')
    free_space=$(vgs --noheadings -o vg_free $vg_name | tr -d ' ')
    if [ "$free_space" != "0" ]; then
        echo -e "\nNote: There is $free_space of unallocated space in the volume group $vg_name for the root filesystem."
        reclaim_available=true
    fi
fi

# Set reclaim option for prompt
if [ "$reclaim_available" = true ]; then
    reclaim_option=" or 'r' to reclaim this space for the root filesystem"
else
    reclaim_option=""
fi

# Prompt user for selection
echo -e "\nEnter the number of the device to mount (1-$((index-1))), the name of a disk to prepare and mount (e.g., /dev/sda)${reclaim_option}:"
read selection

# Handle user selection
if [ "$selection" = "r" ] && [ "$reclaim_available" = true ]; then
    echo "Reclaiming unallocated space for the root filesystem."
    lvextend -l +100%FREE $lv_path
    resize2fs $lv_path
    echo "Root filesystem extended successfully."
elif [[ " ${no_part_disks[@]} " =~ " ${selection} " ]]; then
    echo "Warning: Preparing $selection will partition it as GPT, format it as ext4, and erase all data."
    read -p "Are you sure? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        # Partition as GPT with one primary partition
        parted -s "$selection" mklabel gpt
        parted -s "$selection" mkpart primary ext4 0% 100%
        part="${selection}1"  # First partition

        # Format as ext4
        mkfs.ext4 "$part"

        # Ask for mount point
        read -p "Enter the mount point (e.g., /mnt/): " mountpoint
        mkdir -p "$mountpoint"
        mount "$part" "$mountpoint"

        # Add to /etc/fstab
        uuid=$(blkid -s UUID -o value "$part")
        echo "UUID=$uuid $mountpoint ext4 defaults 0 2" >> /etc/fstab
        echo "Disk $selection prepared and mounted at $mountpoint."
    else
        echo "Operation cancelled."
    fi
elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le $((index-1)) ]; then
    # Mount an existing unmounted partition
    device="${unmounted_parts[$selection]}"
    read -p "Enter the mount point (e.g., /mnt/NAS): " mountpoint
    mkdir -p "$mountpoint"
    mount "$device" "$mountpoint"
    uuid=$(blkid -s UUID -o value "$device")
    echo "UUID=$uuid $mountpoint ext4 defaults 0 2" >> /etc/fstab
    echo "Mounted $device to $mountpoint."
else
    echo "Invalid selection."
fi
