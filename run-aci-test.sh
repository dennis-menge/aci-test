#!/bin/bash
set +e

trap teardown INT

REGIONS="westeurope westus2 eastus northeurope westus australiaeast"

SUBSCRIPTION=$(az account show --query "id" -o tsv)
RG="${1}"

if [[ -z "$RG" ]]; then
    echo "Please specifiy resource group as first script paramter"
    exit 1
fi

if [[ -z "$SUBSCRIPTION" ]]; then
    echo "Please make sure you are logged into Azure via CLI"
    exit 1
fi

function create_vnet(){
    declare name="${1}"
    for region in ${REGIONS}; do
        echo "--> Provisioning ${name} VNET for ACI in ${region}"
        az network vnet create --address-prefixes 10.0.0.0/16 \
                --name "${name}-${region}-network" \
                --resource-group "${RG}" \
                --subnet-name aci-subnet \
                --subnet-prefixes 10.0.0.0/24 \
                --location "${region}"
        az network vnet subnet update \
                --resource-group "${RG}" \
                --name aci-subnet \
                --vnet-name "${name}-${region}-network" \
                --delegations Microsoft.ContainerInstance/containerGroups
        SUBSCRIPTION=${SUBSCRIPTION} RG=${RG} REGION=${region} SUBNET="aci-subnet" VNET="${name}-${region}-network" envsubst < networkprofile.json.template > networkprofile-"${name}-${region}".json
        az rest --method put --url "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.Network/networkProfiles/networkprofile-${name}-${region}?api-version=2020-05-01" \
                --body @networkprofile-"${name}-${region}".json
    done
}

function create_aci(){
    declare name="${1}"
    for region in ${REGIONS}; do
        echo "--> Provisioning ${name} ACI in ${region}"
        SUBSCRIPTION=${SUBSCRIPTION} RG=${RG} REGION="${region}" CONTAINER_NAME="${name}-${region}" envsubst < aci-test.yml.template > aci-test-${name}-${region}.yml
        az container create --resource-group ${RG} \
                --file aci-test-"${name}-${region}".yml \
                --vnet "${name}-${region}-network" \
                --vnet-address-prefix 10.0.0.0/16 \
                --subnet aci-subnet \
                --subnet-address-prefix 10.0.0.0/24 > /dev/null || echo "failure" &
    done
}

function report_running_containers(){
    while true; do
        for instance in $(az container list --resource-group "${RG}" --query "[].name" -o tsv); do
            echo "Checking Kill Signals for ${name}"
            kill_signals=$(az container show --resource-group "${RG}" --name "${instance}" --query "containers[].instanceView.events[].name" | jq  '.[] | select(. == "Killing")' | wc -l)
            echo -e "--> Kill Signals for ${name} received: ${kill_signals}\n"
        done
        echo -e "--> Sleeping 2 minutes until next iteration... \n\n"
        sleep 120;
    done
}

function wait_4_jobs(){
    for job in $(jobs -p); do
        wait "${job}" || ((FAIL++))
    done
}

function cleanup_resource_files(){
    rm networkprofile-"${name}"-*.json
    rm aci-test-"${name}"-*.yml
}

function delete_resources(){
    for instance in $(az container list --resource-group "${RG}" --query "[].name" -o tsv); do
        echo "--> Deleting ${instance} ACI"
        az container delete --yes --resource-group "${RG}" --name "${instance}" > /dev/null
    done
    echo "Sleeping for 90s to let ACI cleanup NICs that are attached to the Network Profile"
    sleep 90
    for n_profile in $(az network profile list --resource-group "${RG}" --query "[].id" -o tsv); do
        echo "--> Deleting ${n_profile} network profile"
        az network profile delete --id "${n_profile}" -y
    done
    for vnet in $(az network vnet list --resource-group "${RG}" --query "[].name" -o tsv); do
        echo "--> Deleting ${vnet} vnet"
        az network vnet delete --resource-group "${RG}" --name "${vnet}" > /dev/null
    done
}

function teardown(){
    echo "Received CTRL-C signal, tearing down..."

    if [ -n "$(jobs -p)" ]; then
        kill "$(jobs -p)"
    fi

    cleanup_resource_files
    delete_resources
    exit 0
}

echo "Creating ACI instances in each of the following regions '${REGIONS}' using resources group '${RG}'"

FAIL=0

name=$(echo "aci-$(openssl rand -hex 3)" | tr '[:upper:]' '[:lower:]')
create_vnet "${name}"
create_aci "${name}"
wait_4_jobs
echo "-> Count of Allocation Failures: ${FAIL}"
report_running_containers