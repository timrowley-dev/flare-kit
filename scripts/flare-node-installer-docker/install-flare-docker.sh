#!/bin/bash
# Flare Node Installer Script
# This script automates the installation and configuration of a Flare network node using Docker.
#
# Requirements:
# - Ubuntu/Debian-based system
# - Root or sudo privileges
# - Internet connection
# - Sufficient disk space for the blockchain database
#
# Usage:
#   ./install-flare-docker.sh [options]
#
# Options:
#   --network <network>     Specify the network (flare|coston|costwo|songbird)
#   --version <version>     Specify the node version (e.g., go-flare:v1.9.1)
#   --http-host <host>      Specify the HTTP host (default: 0.0.0.0)
#   --db-dir <path>         Specify the database directory path
#   --archival              Run node in archival mode (no pruning)
#   --validator             Configure node as a validator
#   --install               Start the installation process
#   --upgrade               Upgrade the node to a new version
#   --dry-run              Show upgrade plan without executing (use with --upgrade)
#   --status                Check node health status
#   --extra-args <args>     Additional arguments to pass to the node
#
# Examples:
#   # Install a Flare observer node
#   ./install-flare-docker.sh --network flare --version go-flare:v1.9.1 --db-dir /mnt/disks/db --install
#
#   # Install a Songbird validator node
#   ./install-flare-docker.sh --network songbird --version go-flare:v1.9.1 --db-dir /mnt/disks/db --validator --install
#
#   # Upgrade node to a new version
#   ./install-flare-docker.sh --network flare --version go-flare:v1.9.2 --upgrade
#
#   # Test upgrade plan without executing
#   ./install-flare-docker.sh --network flare --version go-flare:v1.9.2 --dry-run --upgrade 
#
#   # Check node status
#   ./install-flare-docker.sh --status
#
# Notes:
# - For validator nodes, ensure staking.crt and staking.key files are present in /opt/flare/staking/
# - The script will create necessary directories and set appropriate permissions
# - Docker will be installed if not present
# - The node will be configured to restart automatically on system reboot
# - When upgrading, the script will preserve existing configurations and gracefully stop/start the container
# - Use --dry-run with --upgrade to see the planned changes without executing them [IMPORTANT: MUST BE SPECIFIED *BEFORE* --upgrade flag]

# Error handling
set -euo pipefail
trap 'echo "Error occurred on line $LINENO. Command: $BASH_COMMAND"' ERR

# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 is required but not installed."
        return 1
    fi
    return 0
}

# Function to validate JSON
validate_json() {
    if ! echo "$1" | jq . > /dev/null 2>&1; then
        echo "Error: Invalid JSON configuration"
        return 1
    fi
    return 0
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script requires root privileges"
        return 1
    fi
    return 0
}

cChainConfig='{
  "snowman-api-enabled": false,
  "coreth-admin-api-enabled": false,
  "eth-apis": [
    "eth",
    "eth-filter",
    "admin",
    "debug",
    "net",
    "debug-tracer",
    "web3",
    "internal-eth",
    "internal-blockchain",
    "internal-transaction",
    "internal-tx-pool",
    "internal-debug",
    "internal-account",
    "internal-personal"
  ],
  "rpc-gas-cap": 50000000,
  "rpc-tx-fee-cap": 100,
  "local-txs-enabled": false,
  "api-max-duration": 0,
  "api-max-blocks-per-request": 0,
  "allow-unfinalized-queries": false,
  "allow-unprotected-txs": false,
  "remote-tx-gossip-only-enabled": false,
  "log-level": "info"
}'

cChainConfig_validator='
{
  "snowman-api-enabled": false,
  "coreth-admin-api-enabled": false,
  "coreth-admin-api-dir": "",
  "eth-apis": ["web3", "net"],
  "continuous-profiler-dir": "",
  "continuous-profiler-frequency": 900000000000,
  "continuous-profiler-max-files": 5,
  "rpc-gas-cap": 50000000,
  "rpc-tx-fee-cap": 100,
  "preimages-enabled": false,
  "pruning-enabled": true,
  "snapshot-async": true,
  "snapshot-verification-enabled": false,
  "metrics-enabled": true,
  "metrics-expensive-enabled": false,
  "local-txs-enabled": false,
  "api-max-duration": 30000000000,
  "ws-cpu-refill-rate": 0,
  "ws-cpu-max-stored": 0,
  "api-max-blocks-per-request": 30,
  "allow-unfinalized-queries": false,
  "allow-unprotected-txs": false,
  "keystore-directory": "",
  "keystore-external-signer": "",
  "keystore-insecure-unlock-allowed": false,
  "remote-tx-gossip-only-enabled": false,
  "tx-regossip-frequency": 60000000000,
  "tx-regossip-max-size": 15,
  "log-level": "info",
  "offline-pruning-enabled": false,
  "offline-pruning-bloom-filter-size": 512,
  "offline-pruning-data-directory": ""
}
'

get_health_status () {
    curl_health=$(curl -s http://localhost:9650/ext/health)
    healthy_value=$(echo "$curl_health" | jq -r '.healthy')
    connected_peers_value=$(echo "$curl_health" | jq -r '.checks.network.message.connectedPeers')

    curl_version=$(curl -s --location 'http://localhost:9650/ext/info' --header 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeVersion","params" :[]}')
    node_verson=$(echo "$curl_version" | jq -r '.result.version')
    
    echo "Healthy: $healthy_value"
    echo "Connected Peers: $connected_peers_value"
    echo "Node Version: $node_verson"
}

install_jq () {
   if ! command -v jq &> /dev/null; then
            echo "Installing jq package..."
            
            # Install jq on Ubuntu
            sudo apt-get update
            sudo apt-get install -y jq

            # Check if installation was successful
            if [ $? -eq 0 ]; then
               echo ""
               echo "jq has been successfully installed."
               echo ""
            else
               echo "Installation of jq failed. Please install it manually."
               exit 1
            fi
   fi
}

get_bootstrap_endpoint () {
    case "$networkParam" in
        flare)
            echo "https://flare-bootstrap.flare.network/ext/info"
            ;;
        coston)
            echo "https://coston-bootstrap.flare.network/ext/info"
            ;;
        costwo)
            echo "https://coston2-bootstrap.flare.network/ext/info"
            ;;
        songbird)
            echo "https://songbird-bootstrap.flare.network/ext/info"
            ;;
        *)
            echo "Unknown network: $networkParam"
            exit 1
            ;;
    esac
}

install_docker () {
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        
        # Update the package index
        sudo apt-get update

        # Install required packages
        sudo apt-get install -y \
            acl \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            software-properties-common

        # Remove existing Docker GPG key if it exists
        sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg

        # Add Docker's official GPG key (non-interactive)
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

        # Add the Docker repository
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
            https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Update the package index again
        sudo apt-get update

        # Install the latest version of Docker (non-interactive)
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io

        # Create docker group if it doesn't exist
        if ! getent group docker >/dev/null; then
            sudo groupadd docker
        fi

        # Add current user to docker group
        sudo usermod -aG docker "$USER"

        # Check if installation was successful
        if [ $? -eq 0 ]; then
            echo "Docker has been successfully installed."
            # Start docker service
            sudo systemctl start docker
            # Set permissions on docker socket
            sudo chmod 666 /var/run/docker.sock
        else
            echo "Error: Installation of Docker failed."
            exit 1
        fi
    else
        # If Docker is already installed, ensure user is in docker group
        if ! groups | grep -q docker; then
            sudo usermod -aG docker "$USER"
        fi
        echo "Docker is already installed."
    fi
}

# Function to check if user has docker access
check_docker_access() {
    if ! docker info >/dev/null 2>&1; then
        echo "Setting permissions on docker socket..."
        sudo chmod 666 /var/run/docker.sock
    fi
}

install_node () {
   # Create directories
   echo "Creating directories"
   create_directories

   if [[ "$pruningEnabledParam" != "true" && "$pruningEnabledParam" != "false" ]]; then
      echo "Defaulting pruning to true"
      pruningEnabledParam="true"
   fi

   if [[ "$isValidatorParam" == "false" ]]; then
      config="$cChainConfig"
      # TODO: Validate this sets pruning to false when --archival is used
      config=$(echo "$config" | jq --arg pruningEnabled "$pruningEnabledParam" '.["pruning-enabled"] = ($pruningEnabled == "true")')
   else
      config="$cChainConfig_validator"
   fi

   # Write cChainConfig to file
   echo "$config" | sudo tee /opt/flare/conf/config.json > /dev/null

   # Get bootstrap endpoint
   bootstrap_endpoint=$(get_bootstrap_endpoint)

   # Pull docker image 
   docker pull flarefoundation/"$nodeTagParam"

   # Build extra arguments string
   extra_args=""
   if [[ -n "$extraArgsParam" ]]; then
      extra_args="-e EXTRA_ARGUMENTS=\"$extraArgsParam\""
   fi

   if [[ "$isValidatorParam" == "false" ]]; then
      docker run -d --name "$networkParam"-observer \
      --restart always \
      -e AUTOCONFIGURE_BOOTSTRAP="1" \
      -e NETWORK_ID="$networkParam" \
      -e AUTOCONFIGURE_PUBLIC_IP="1" \
      -e AUTOCONFIGURE_BOOTSTRAP_ENDPOINT="$bootstrap_endpoint" \
      -e HTTP_HOST="$httpHostParam" \
      $extra_args \
      -v "$dbDirParam":/app/db \
      -v /opt/flare/conf:/app/conf/C \
      -v /opt/flare/logs:/app/logs \
      -p "$httpHostParam":9650:9650 \
      -p "$httpHostParam":9651:9651 \
      "flarefoundation/$nodeTagParam"
   else
      # For validators, combine staking args with any extra args
      staking_args="--staking-tls-cert-file=/app/staking/staker.crt --staking-tls-key-file=/app/staking/staker.key"
      if [[ -n "$extraArgsParam" ]]; then
         staking_args="${staking_args} ${extraArgsParam}"
      fi
      
      docker run -d --name "$networkParam"-validator \
      --restart always \
      -e AUTOCONFIGURE_BOOTSTRAP="1" \
      -e NETWORK_ID="$networkParam" \
      -e AUTOCONFIGURE_PUBLIC_IP="1" \
      -e AUTOCONFIGURE_BOOTSTRAP_ENDPOINT="$bootstrap_endpoint" \
      -e HTTP_HOST="$httpHostParam" \
      -e EXTRA_ARGUMENTS="$staking_args" \
      -v "$dbDirParam":/app/db \
      -v /opt/flare/conf:/app/conf/C \
      -v /opt/flare/logs:/app/logs \
      -v /opt/flare/staking:/app/staking \
      -p "$httpHostParam":9650:9650 \
      -p "$httpHostParam":9651:9651 \
      "flarefoundation/$nodeTagParam"
   fi
   # Run docker container
   

      echo "==== Node Installed! ===="
      echo "Network: $networkParam"
      echo "HTTP Host: $httpHostParam"
      echo "DB Directory: $dbDirParam"
      echo "Logs Directory: /opt/flare/logs"
      echo "Config Directory: /opt/flare/config"
      echo "Node Version: $nodeTagParam"
      echo "Pruning Enabled: $pruningEnabledParam"
}

# --staking-tls-cert-file=<NODE_CRT_PATH> --staking-tls-key-file=<NODE_KEY_PATH>
# --staking-tls-cert-file=/app/staking/staking.crt --staking-tls-key-file=/app/staking/staking.key



create_directories () {
    # Create directories if they do not exist
    if [ ! -d /opt/flare/conf ]; then
        sudo mkdir -p /opt/flare/conf
    fi

    if [ ! -d /opt/flare/logs ]; then
        sudo mkdir -p /opt/flare/logs
    fi

    # Get current user
    CURRENT_USER=$(whoami)

    # Set ownership to current user and docker group
    sudo chown -R "${CURRENT_USER}:docker" /opt/flare

    # Set directory permissions to allow group access
    sudo chmod -R g+rwX /opt/flare
}

validate_variables () {
    # Check required commands
    check_command curl || exit 1
    check_command jq || exit 1

    if [ -z "$networkParam" ]; then
        echo "Error: Network is required"
        exit 1
    fi

    if [ -z "$nodeTagParam" ]; then
        echo "Error: Node Version is required"
        exit 1
    fi

    if [ -z "$dbDirParam" ]; then
        echo "Error: DB Directory is required"
        exit 1
    fi 

    # Validate network parameter
    case "$networkParam" in
        flare|coston|costwo|songbird)
            ;;
        *)
            echo "Error: Invalid network: $networkParam"
            exit 1
            ;;
    esac

    # Create DB directory if it doesn't exist
    if [ ! -d "$dbDirParam" ]; then
        echo "Creating DB directory: $dbDirParam"
        sudo mkdir -p "$dbDirParam"
    fi

    if [[ "$isValidatorParam" == "true" ]]; then
        if [ ! -d /opt/flare/staking ]; then
            sudo mkdir -p /opt/flare/staking
            echo "Staking directory created; please add your staking.crt and staking.key files to the /opt/flare/staking directory before proceeding."
            exit 1
        fi

        if [[ "$pruningEnabledParam" == "false" ]]; then
            echo "Error: This script does not support archival nodes that are validators."
            exit 1
        fi
    fi
}

setup_permissions() {
    # Get current user
    CURRENT_USER=$(whoami)
    
    echo "Setting up permissions for directories..."
    
    # Create necessary directories
    sudo mkdir -p /opt/flare/conf
    sudo mkdir -p /opt/flare/logs
    if [[ "$isValidatorParam" == "true" ]]; then
        sudo mkdir -p /opt/flare/staking
    fi
    
    # Set ownership and permissions for DB directory
    sudo chown -R "${CURRENT_USER}:docker" "$dbDirParam"
    sudo chmod -R g+rwX "$dbDirParam"
    
    # Set ownership and permissions for flare directories
    sudo chown -R "${CURRENT_USER}:docker" /opt/flare
    sudo chmod -R g+rwX /opt/flare
}

install () {
   validate_variables

   if [[ "$pruningEnabledParam" == "false" ]]; then
   echo "Warning: Pruning is disabled. Ensure this is intended. Database will be significantly larger than pruning."
   printf "\n"
   fi

   echo "Network: $networkParam"
   echo "HTTP Host: $httpHostParam"
   echo "DB Directory: $dbDirParam"
   echo "Logs Directory: /opt/flare/logs"
   echo "Config Directory: /opt/flare/config"
   echo "Node Version: $nodeTagParam"
   echo "Pruning Enabled: $pruningEnabledParam" 
   echo "Is Validator: $isValidatorParam" 
   echo "Extra Arguments: $extraArgsParam"
   printf "\n"
   echo "Starting installation in 3 seconds..."
   
   sleep 5

   install_jq
   install_docker
   check_docker_access

   # Check if Docker was successfully installed
   if ! command -v docker &> /dev/null; then
       echo "Error: Docker installation failed"
       exit 1
   fi

   # Setup permissions after Docker is installed
   setup_permissions

   install_node
}

upgrade_node() {
    echo "Starting node upgrade process..."
    
    # Validate required parameters
    if [ -z "$networkParam" ]; then
        echo "Error: Network is required for upgrade"
        exit 1
    fi

    if [ -z "$nodeTagParam" ]; then
        echo "Error: New version is required for upgrade"
        exit 1
    fi

    # Determine container name based on network and type
    if [[ "$isValidatorParam" == "true" ]]; then
        container_name="${networkParam}-validator"
    else
        container_name="${networkParam}-observer"
    fi

    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Error: Container ${container_name} not found"
        exit 1
    fi

    # Get the existing container's configuration
    echo "Retrieving existing container configuration..."
    old_container_id=$(docker ps -a -q -f name="${container_name}")
    if [ -z "$old_container_id" ]; then
        echo "Error: Could not find old container configuration"
        exit 1
    fi

    # Get current version for comparison
    current_container_version=$(docker inspect --format '{{.Config.Image}}' "${old_container_id}")

    # Get container configuration in JSON format
    container_config=$(docker inspect "${old_container_id}")

    # Extract environment variables safely using jq
    env_vars=()
    while IFS= read -r env_var; do
        if [ -n "$env_var" ]; then
            env_vars+=("$env_var")
        fi
    done < <(echo "$container_config" | jq -r '.[0].Config.Env[]')

    # Extract volume mounts safely using jq
    volumes=()
    while IFS= read -r volume; do
        if [ -n "$volume" ]; then
            volumes+=("$volume")
        fi
    done < <(echo "$container_config" | jq -r '.[0].Mounts[] | "\(.Source):\(.Destination)"')

    # Build docker run command with environment variables
    docker_cmd="docker run -d --name ${container_name} --restart always"
    
    # Add environment variables
    for env_var in "${env_vars[@]}"; do
        docker_cmd+=" -e \"${env_var}\""
    done
    
    # Add volume mounts
    for volume in "${volumes[@]}"; do
        docker_cmd+=" -v \"${volume}\""
    done
    
    # Add port mappings and image
    docker_cmd+=" -p ${httpHostParam}:9650:9650 -p ${httpHostParam}:9651:9651 flarefoundation/${nodeTagParam}"

    # Validate version exists (for both dry-run and actual upgrade)
    echo "Validating new version ${nodeTagParam}..."
    if ! docker manifest inspect flarefoundation/"${nodeTagParam}" > /dev/null 2>&1; then
        echo "Error: Version ${nodeTagParam} is not available or invalid"
        exit 1
    fi

    if [ "$dryRunParam" == "true" ]; then
        echo "=== DRY RUN - No changes will be made ==="
        echo "Current container: ${container_name}"
        echo "Current version: ${current_container_version}"
        echo "New version: ${nodeTagParam}"
        echo ""
        echo "Environment variables to be preserved:"
        printf '%s\n' "${env_vars[@]}"
        echo ""
        echo "Volume mounts to be preserved:"
        printf '%s\n' "${volumes[@]}"
        echo ""
        echo "Docker run command that would be executed:"
        echo "$docker_cmd"
        echo ""
        echo "=== End of dry run ==="
        exit 0
    fi

    if [ "$current_container_version" == "flarefoundation/${nodeTagParam}" ]; then
        echo "Warning: Container is already running version ${nodeTagParam}"
        read -p "Do you want to continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Upgrade cancelled"
            exit 0
        fi
    fi

    # Check if container is running
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Stopping container ${container_name}..."
        docker stop "${container_name}"
    fi

    # Remove the old container
    echo "Removing old container..."
    docker rm "${container_name}"

    # Create the new container with the same configuration
    echo "Creating new container with updated version..."
    
    # Execute the docker run command
    eval "$docker_cmd"

    echo "Upgrade completed successfully!"
    echo "New version: ${nodeTagParam}"
    echo "Container name: ${container_name}"
    echo "You can check the status using: ./install-flare-docker.sh --status"
}

nodeTagParam=""
pruningEnabledParam="true"
httpHostParam="0.0.0.0"
dbDirParam=""
networkParam=""
isValidatorParam="false"
dryRunParam="false"
extraArgsParam=""

# Example commands
# --network flare --version go-flare:v1.9.1 --http-host 0.0.0.0 --db-dir /mnt/disks/db --install
# --network flare --version go-flare:v1.9.1 --http-host 0.0.0.0 --db-dir /mnt/disks/db --extra-args "--some-arg=value" --install

while [[ $# -gt 0 ]]; do
   key="$1"
   case $key in
      --network)              # VARIABLE
         networkParam="$2"
         shift
         shift
         ;;
      --version)              # VARIABLE
         nodeTagParam="$2"
         shift 
         shift
         ;;
      --http-host)            # VARIABLE
         httpHostParam="$2"
         shift 
         shift 
         ;;
      --db-dir)               # VARIABLE
         dbDirParam="$2"
         shift 
         shift
         ;;
      --archival)             # VARIABLE
         pruningEnabledParam="false"
         shift 
         ;;
      --validator)             # VARIABLE
         isValidatorParam="true"
         shift 
         ;;
      --extra-args)           # VARIABLE
         extraArgsParam="$2"
         shift
         shift
         ;;
      --dry-run)             # VARIABLE
         dryRunParam="true"
         shift 
         ;;
      --install)              # FUNCTION
         install
         shift 
         ;;
      --upgrade)              # FUNCTION
         upgrade_node
         shift 
         ;;
      --status)               # FUNCTION
         get_health_status
         exit 0
         ;;
      *)
         # Unknown option
         echo "Unknown option: $1"
         exit 1
         ;;
   esac
done
