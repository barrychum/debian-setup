#!/bin/bash

# ==============================================================================
# DESCRIPTION: configure network interfaces, disable IPv6, and enable root SSH login. 
# ==============================================================================

# Set variables for file paths
interfaces_file="/etc/network/interfaces"
sysctl_file="/etc/sysctl.conf"
ssh_config_file="/etc/ssh/sshd_config"
timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

# Function to add a change log entry to a file.
# It first checks if the log header exists, then appends the entry.
add_change_log_label() {
    local log_file=$1
    local log_message=$2

    if ! grep -q "## Change log ##" "$log_file"; then
        echo "" >> "$log_file"
        echo "## Change log ##" >> "$log_file"
    fi
    echo "# $timestamp $log_message" >> "$log_file"
}

# Function to convert a CIDR prefix (e.g., 24) to a dotted-decimal netmask.
cidr_to_netmask() {
    local cidr=$1
    local octet
    local netmask_octets=()

    for i in {1..4}; do
        if [[ $cidr -ge 8 ]]; then
            netmask_octets+=("255")
            cidr=$((cidr - 8))
        else
            bits_to_shift=$((8 - cidr))
            octet=$((256 - (1 << bits_to_shift)))
            netmask_octets+=("$octet")
            cidr=0
        fi
    done
    echo "${netmask_octets[0]}.${netmask_octets[1]}.${netmask_octets[2]}.${netmask_octets[3]}"
}

# --- Network Interface Configuration ---

echo "--- Configuring Network Interface ---"

# Find the primary IP address and default gateway
ip_cidr=$(ip -o -f inet addr show | grep -v '127.0.0.1' | awk '{print $4}' | head -n 1)
default_gateway=$(ip route | grep default | awk '{print $3}')
default_iface=$(ip -o -f inet addr show | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1)
ip_address=${ip_cidr%/*}
cidr_prefix=${ip_cidr#*/}
netmask=$(cidr_to_netmask "$cidr_prefix")

# Check for a valid IP address
if [[ -z "$ip_address" ]]; then
    echo "Error: Could not determine the IP address. Exiting."
    exit 1
fi

echo "Current IP Address: $ip_address"
echo "Default Gateway:    ${default_gateway:-Not Found}"
echo "CIDR Prefix:        /$cidr_prefix"
echo "Netmask:            $netmask"

# Prompt for the interface name, using the default if none is entered
echo ""
echo "Enter interface name to modify, or press enter to set default \"$default_iface\""
read ifname

if [[ -z "$ifname" ]]; then
    ifname="$default_iface"
fi
echo "Setting interface $ifname"

# Check if the interfaces file exists
if [[ ! -f "$interfaces_file" ]]; then
    echo "Error: The file '$interfaces_file' was not found. Cannot configure network interfaces."
else
    # Check if the interface has already been modified
    if ! grep -q "changed interface" "$interfaces_file"; then
        echo "Please enter new IP"
        read ip
        # Use a single sed command for all modifications to the file
        sed -i -e "s/iface $ifname inet dhcp/iface $ifname inet static/" \
               -e "/iface $ifname inet static/ a address $ip" \
               -e "/iface $ifname inet static/ a netmask $netmask" \
               -e "/iface $ifname inet static/ a gateway $default_gateway" "$interfaces_file"

        # Apply network changes
        ip addr flush "$ifname" && systemctl restart networking
        ifup "$ifname"

        add_change_log_label "$interfaces_file" "*changed interface*"
    else
        echo "Interface already configured. Skipping modification."
    fi
fi

# --- Disable IPv6 ---

echo ""
echo "--- Disabling IPv6 ---"
if [[ ! -f "$sysctl_file" ]]; then
    echo "Error: The file '$sysctl_file' was not found. Cannot disable IPv6."
else
    if ! grep -q "*ipv6disabled*" "$sysctl_file"; then
        sed -i -e "\$a\ " \
               -e "\$a# Script added lines to disable IPv6" \
               -e "\$anet.ipv6.conf.$ifname.disable_ipv6=1" \
               -e "\$anet.ipv6.conf.lo.disable_ipv6=1" \
               -e "\$anet.ipv6.conf.default.disable_ipv6=1" \
               -e "\$anet.ipv6.conf.all.disable_ipv6=1" \
               -e "\$a#ipv6disabled" "$sysctl_file"

        sysctl -p

        add_change_log_label "$sysctl_file" "*ipv6disabled*"
    else
        echo "IPv6 already disabled. Skipping modification."
    fi
fi

# --- Enable Remote SSH ---

echo ""
echo "--- Enabling Remote SSH ---"
if [[ ! -f "$ssh_config_file" ]]; then
    echo "Error: The file '$ssh_config_file' was not found. Cannot enable SSH."
else
    if ! grep -q "*PermitRootLoginChanged*" "$ssh_config_file"; then
        sed -i -e "s/#PermitRootLogin.*/PermitRootLogin yes/" "$ssh_config_file"

        systemctl restart sshd

        add_change_log_label "$ssh_config_file" "*PermitRootLoginChanged*"
    else
        echo "Root SSH login already enabled. Skipping modification."
    fi
fi
