#!/bin/bash

# NOTE: In `config/rollup-config.json`, `l1_sudt_cell_dep` identifies the l1_sudt cell located at the genesis block of CKB. Please type `ckb -C docker/layer1/ckb list-hash` for more information.

set -o errexit

WORKSPACE="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
CONFIG_DIR="$WORKSPACE/config"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-"ACCOUNTS_DIR is required"}"
CKB_MINER_PID=""
GODWOKEN_PID=""
CHAIN_ID=71400

function start-ckb-miner-at-background() {
    ckb -C $CONFIG_DIR miner &> /dev/null &
    CKB_MINER_PID=$!
    log "ckb-miner is mining..."
}

function stop-ckb-miner() {
    log "Kill the ckb-miner process"
    if [ ! -z "$CKB_MINER_PID" ]; then
        kill $CKB_MINER_PID
        CKB_MINER_PID=""
    fi
}

function start-godwoken-at-background() {
    log "Starting"
    start_time=$(date +%s)
    godwoken run -c $CONFIG_DIR/godwoken-config.toml & # &> /dev/null &
    GODWOKEN_PID=$!
    while true; do
        sleep 1
        result=$(curl http://127.0.0.1:8119 &> /dev/null || echo "Godwoken not started")
        if [ "$result" != "Godwoken not started" ]; then
            break
        fi
        elapsed=$(( $(date +%s) - start_time ))
        if [ $elapsed -gt 10 ]; then
            log "ERROR: start godwoken timeout"
            exit 2
        fi
    done
    log "Godwoken started"
}

# Notice: Be careful, if you you try to stop Godwoken in the early phase,
# you should make sure that the Polyjuice root account is created and the layer2 block is synced.
#
# Try to avoid restarting Godwoken if you can.
function stop-godwoken() {
    log "Killing the Godwoken process"
    if [ ! -z "$GODWOKEN_PID" ]; then
        kill $GODWOKEN_PID
        GODWOKEN_PID=""
    fi
    while true; do
        log "Wait until Godwoken exitted" && sleep 2
        result=$(curl http://127.0.0.1:8119 &> /dev/null && echo "Godwoken is running")
        if [ "$result" != "Godwoken is running" ]; then
            break
        fi 
    done
    log "Done"
}

# The scripts-config.json file records the names and locations of all scripts
# that have been compiled in docker image. These compiled scripts will be
# deployed, and the deployment result will be stored into scripts-deployment.json.
# 
# To avoid redeploying, this command skips scripts-deployment.json if it already
# exists.
#
# More info: https://github.com/nervosnetwork/godwoken-docker-prebuilds/blob/97729b15093af6e5f002b46a74c549fcc8c28394/Dockerfile#L42-L54
function deploy-scripts() {
    log "Start"
    if [ -s "$CONFIG_DIR/scripts-deployment.json" ]; then
        log "$CONFIG_DIR/scripts-deployment.json already exists, skip"
        return 0
    fi

    start-ckb-miner-at-background
    RUST_BACKTRACE=full gw-tools deploy-scripts \
        --ckb-rpc http://ckb:8114 \
        -i $CONFIG_DIR/scripts-config.json \
        -o $CONFIG_DIR/scripts-deployment.json \
        -k $ACCOUNTS_DIR/rollup-scripts-deployer.key
    stop-ckb-miner

    log "Generate file \"$CONFIG_DIR/scripts-deployment.json\""
    log "Finished"
}

function deploy-rollup-genesis() {
    log "start"
    if [ -s "$CONFIG_DIR/rollup-genesis-deployment.json" ]; then
        log "$CONFIG_DIR/rollup-genesis-deployment.json already exists, skip"
        return 0
    fi

    start-ckb-miner-at-background
    RUST_BACKTRACE=full gw-tools deploy-genesis \
        --ckb-rpc http://ckb:8114 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --omni-lock-config-path $CONFIG_DIR/scripts-deployment.json \
        --rollup-config $CONFIG_DIR/rollup-config.json \
        -o $CONFIG_DIR/rollup-genesis-deployment.json \
        -k $ACCOUNTS_DIR/godwoken-block-producer.key
    stop-ckb-miner
    log "Generate file \"$CONFIG_DIR/rollup-genesis-deployment.json\""
}

function generate-godwoken-config() {
    log "start"
    if [ -s "$CONFIG_DIR/godwoken-config.toml" ]; then
        log "$CONFIG_DIR/godwoken-config.toml already exists, skip"
        return 0
    fi

    # Node: 0x2e9df163055245bfadd35e3a1f05f06096447c85 is the eth_address of
    # `godwoken-block-producer.key`
    RUST_BACKTRACE=full gw-tools generate-config \
        --ckb-rpc http://ckb:8114 \
        --ckb-indexer-rpc http://ckb-indexer:8116 \
        -c $CONFIG_DIR/scripts-config.json \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --omni-lock-config-path $CONFIG_DIR/scripts-deployment.json \
        -g $CONFIG_DIR/rollup-genesis-deployment.json \
        --rollup-config $CONFIG_DIR/rollup-config.json \
        -o $CONFIG_DIR/godwoken-config.toml \
        --rpc-server-url 0.0.0.0:8119 \
        --privkey-path $ACCOUNTS_DIR/godwoken-block-producer.key \
        --block-producer-address 0x2e9df163055245bfadd35e3a1f05f06096447c85

    # some dirty modification
    if [ ! -z "$GODWOKEN_MODE" ]; then
        sed -i 's#^node_mode = .*$#node_mode = '"'$GODWOKEN_MODE'"'#' $CONFIG_DIR/godwoken-config.toml
    fi
    if [ ! -z "$STORE_PATH" ]; then
        sed -i 's#^path = .*$#path = '"'$STORE_PATH'"'#' $CONFIG_DIR/godwoken-config.toml
    fi
    sed -i 's#enable_methods = \[\]#err_receipt_ws_listen = '"'0.0.0.0:8120'"'#' $CONFIG_DIR/godwoken-config.toml

    log "Generate file \"$CONFIG_DIR/godwoken-config.toml\""
}

function create-polyjuice-root-account() {
    log "start"
    if [ -s "$CONFIG_DIR/polyjuice-root-account-id" ]; then
        log "$CONFIG_DIR/polyjuice-root-account-id already exists, skip"
        return 0
    fi

    start-ckb-miner-at-background

    # Deposit for block_producer
    log "Deposit for block_producer"
    RUST_BACKTRACE=full gw-tools deposit-ckb \
        --privkey-path $ACCOUNTS_DIR/godwoken-block-producer.key \
        --godwoken-rpc-url http://127.0.0.1:8119 \
        --ckb-rpc http://ckb:8114 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --config-path $CONFIG_DIR/godwoken-config.toml \
        --capacity 2000

    # Create Polyjuice root account (this is a layer2 transaction)
    log "Create Polyjuice root account"
    RUST_BACKTRACE=full gw-tools create-creator-account \
        --privkey-path $ACCOUNTS_DIR/godwoken-block-producer.key \
        --godwoken-rpc-url http://127.0.0.1:8119 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --config-path $CONFIG_DIR/godwoken-config.toml \
        --sudt-id 1 \
    2>&1 | tee /var/tmp/gw-tools.log

    stop-ckb-miner

    tail -n 1 /var/tmp/gw-tools.log | grep -oE '[0-9]+$' > $CONFIG_DIR/polyjuice-root-account-id
    log "Generate file \"$CONFIG_DIR/polyjuice-root-account-id\""
}

function generate-web3-config() {
    log "Start"
    if [ -s "$CONFIG_DIR/web3-config.env" ]; then
        log "$CONFIG_DIR/web3-config.env already exists, skip"
        return 0
    fi

    if ! command -v jq &> /dev/null; then
        apt-get install -y jq &>/dev/null
    fi

    creator_account_id=$(cat $CONFIG_DIR/polyjuice-root-account-id)

    
    cat <<EOF > $CONFIG_DIR/web3-config.env
ROLLUP_TYPE_HASH=$(jq -r '.rollup_type_hash' $CONFIG_DIR/rollup-genesis-deployment.json)
ETH_ACCOUNT_LOCK_HASH=$(jq -r '.eth_account_lock.script_type_hash' $CONFIG_DIR/scripts-deployment.json)
POLYJUICE_VALIDATOR_TYPE_HASH=$(jq -r '.polyjuice_validator.script_type_hash' $CONFIG_DIR/scripts-deployment.json)
L2_SUDT_VALIDATOR_SCRIPT_TYPE_HASH=$(jq -r '.l2_sudt_validator.script_type_hash' $CONFIG_DIR/scripts-deployment.json)

DATABASE_URL=postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@postgres:5432/$POSTGRES_DB
REDIS_URL=redis://redis:6379
GODWOKEN_JSON_RPC=http://godwoken:8119
GODWOKEN_WS_RPC_URL=ws://godwoken:8120
PORT=8024

# The CHAIN_ID is the identifier of our Godwoken devnet, which is defined in
# Godwoken [RollupConfig#chain_id](https://github.com/nervosnetwork/godwoken/blob/a099f2010b212355f5504a8d464b6b70d29640a5/crates/types/schemas/godwoken.mol#L64).
#
# More about chain id:
# * https://eips.ethereum.org/EIPS/eip-1344#specification
CHAIN_ID=$CHAIN_ID

# Polyjuice Root Account
# see: https://github.com/nervosnetwork/godwoken/blob/develop/docs/life_of_a_polyjuice_transaction.md#root-account--deployment
CREATOR_ACCOUNT_ID=$creator_account_id

# When requesting to "executeTransaction" RPC interface, the RawL2Transaction's
# signature can be omit. Therefore we fill the RawL2Transaction.from_id
# with this DEFAULT_FROM_ID (corresponding to DEFAULT_FROM_ADDRESS).
#
# Usually, ID(3) indicates the first deposited Godwoken account.
DEFAULT_FROM_ID=3
DEFAULT_FROM_ADDRESS=0x2e9df163055245bfadd35e3a1f05f06096447c85

# The builtin ETH_ADDRESS_REGISTRY_ACCOUNT_ID is 2.
# see: https://github.com/nervosnetwork/godwoken/blob/6180f04/crates/common/src/builtins.rs#L5
ETH_ADDRESS_REGISTRY_ACCOUNT_ID=2
EOF

    log "Generate file \"$CONFIG_DIR/web3-config.env\""
    log "Finished"
}

function generate-web3-indexer-config() {
    log "Start"
    if [ -s "$CONFIG_DIR/web3-indexer-config.toml" ]; then
        log "$CONFIG_DIR/web3-indexer-config.toml already exists, skip"
        return 0
    fi

    source $CONFIG_DIR/web3-config.env
    cat <<EOF > $CONFIG_DIR/web3-indexer-config.toml
chain_id=$CHAIN_ID
l2_sudt_type_script_hash="$L2_SUDT_VALIDATOR_SCRIPT_TYPE_HASH"
polyjuice_type_script_hash="$POLYJUICE_VALIDATOR_TYPE_HASH"
rollup_type_hash="$ROLLUP_TYPE_HASH"
eth_account_lock_hash="$ETH_ACCOUNT_LOCK_HASH"
godwoken_rpc_url="$GODWOKEN_JSON_RPC"
pg_url="$DATABASE_URL"
ws_rpc_url="$GODWOKEN_WS_RPC_URL"
EOF

    log "Generate file \"$CONFIG_DIR/web3-indexer-config.toml\""
    log "Finished"
}

function log() {
    echo "[${FUNCNAME[1]}] $1"
}

function main() {
    godwoken --version
    gw-tools --version

    # Setup Godwoken at the first time
    deploy-scripts
    deploy-rollup-genesis
    generate-godwoken-config

    start-godwoken-at-background

    # Should make sure that the Polyjuice root account was created and the layer2 block was synced
    create-polyjuice-root-account

    generate-web3-config
    generate-web3-indexer-config

    # Godwoken daemon
    while true; do
        result=$(curl http://127.0.0.1:8119 &> /dev/null || echo "wake up")
        if [ "$result" == "wake up" ]; then
            godwoken run -c $CONFIG_DIR/godwoken-config.toml || echo "Godwoken exit"
        fi
        sleep 30
    done
}

main "$@"
