#!/bin/bash
# WARNING: For automated pipelines, make a private copy of any scripts you use, never pull from a public repository in automated setups.

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
        coston2)
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
           software-properties-common

       # Add Docker's official GPG key
       curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

       # Add the Docker APT repository
       sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

       # Update the package index again
       sudo apt-get update

       # Install the latest version of Docker
       sudo apt-get install -y docker-ce

      # give user permission to use docker
      sudo setfacl -m user:"$USER":rw /var/run/docker.sock

       # Check if installation was successful
       if [ $? -eq 0 ]; then
           echo "Docker has been successfully installed."
           echo "You can now run Docker commands without needing to log out."
       else
           echo "Installation of Docker failed. Please install it manually."
           exit 1
       fi
   else
       echo "Docker is already installed."
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


   if [[ "$isValidatorParam" == "false" ]]; then
      docker run -d --name "$networkParam"-observer \
      --restart always \
      -e AUTOCONFIGURE_BOOTSTRAP="1" \
      -e NETWORK_ID="$networkParam" \
      -e AUTOCONFIGURE_PUBLIC_IP="1" \
      -e AUTOCONFIGURE_BOOTSTRAP_ENDPOINT="$bootstrap_endpoint" \
      -e HTTP_HOST="$httpHostParam" \
      -v "$dbDirParam":/app/db \
      -v /opt/flare/conf:/app/conf/C \
      -v /opt/flare/logs:/app/logs \
      -p "$httpHostParam":9650:9650 \
      -p "$httpHostParam":9651:9651 \
      flarefoundation/"$nodeTagParam"
   else
      docker run -d --name "$networkParam"-validator \
      --restart always \
      -e AUTOCONFIGURE_BOOTSTRAP="1" \
      -e NETWORK_ID="$networkParam" \
      -e AUTOCONFIGURE_PUBLIC_IP="1" \
      -e AUTOCONFIGURE_BOOTSTRAP_ENDPOINT="$bootstrap_endpoint" \
      -e HTTP_HOST="$httpHostParam" \
      -e EXTRA_ARGUMENTS="--staking-tls-cert-file=/app/staking/staker.crt --staking-tls-key-file=/app/staking/staker.key" \
      -v "$dbDirParam":/app/db \
      -v /opt/flare/conf:/app/conf/C \
      -v /opt/flare/logs:/app/logs \
      -v /opt/flare/staking:/app/staking \
      -p "$httpHostParam":9650:9650 \
      -p "$httpHostParam":9651:9651 \
      flarefoundation/"$nodeTagParam"
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

    sudo chown -R ubuntu:ubuntu /opt/flare
}

validate_variables () {

   if [ -z "$networkParam" ]; then
      echo "Network is required"
      exit 1
   fi

   if [ -z "$nodeTagParam" ]; then
      echo "Node Version is required"
      exit 1
   fi

   if [ -z "$dbDirParam" ]; then
      echo "DB Directory is required"
      exit 1
   fi 

   if [[ "$isValidatorParam" == "true" ]]; then
      if [ ! -d /opt/flare/staking ]; then
         sudo mkdir -p /opt/flare/staking
         echo "Staking directory created; please add your staking.crt and staking.key files to the /opt/flare/staking directory before proceeding."
         exit 1
      fi

      if [[ "$pruningEnabledParam" == "false" ]]; then
         echo "This script does not support archival nodes that are validators."
         exit 1
      fi
   fi
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
   printf "\n"
   echo "Starting installation in 3 seconds..."
   
   sleep 5

   install_jq
   install_docker
   install_node
}

nodeTagParam=""
pruningEnabledParam="true"
httpHostParam="0.0.0.0"
dbDirParam=""
networkParam=""
isValidatorParam="false"

# Example commands
# --network flare --version go-flare:v1.9.1 --http-host 0.0.0.0 --db-dir /mnt/disks/db --install

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
      --install)              # FUNCTION
         install
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
