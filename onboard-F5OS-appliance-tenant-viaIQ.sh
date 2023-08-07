#!/bin/bash
# onboard-F5OS-appliance-tenant-viaIQ.sh will deploy a tenant on rSeries 
# and then perform the necessary onboarding directly via BIG-IQ. 
#
# The steps the scripts takes are as follows
# . Communicate with rSeries F5OS appliance
# . Create a Tenant 
# .. Wait for Tenant to become available - currently no simple way to interrogate availability so a PING of the mgt address is what I do
# . Reset the Password
# . via BIG-IQ - Perform the Declarative Onboarding
# . Script complete and ready for AS3 deployment or Appliance migration
#
# For simplicity, I have created a local password file, for the script to connect to. So the password is not in this script. ../PW.txt
#
# Please ensure the correct vlans are in use by the script. At the moment this is hardcoded in the script. See the API post to the
# newly created BIG-IP. The vlans will need to be set accordingly. This should be added as a parameter used by the execution of the script.
#
# Since the onboarding process is managed by BIG-IQ the declarative onboarding rpm is NOT required for the BIG-IP to be deployed.
#

#Function onboard via BIG-IQ
onboard () {
    #Call function to onboard via IQ - values = <targetBIG-IQ> <username> <password> <FQDN> <targetBIG-IP> <lastOctectProductionInterfaces>
    tokenString=`curl -s -X POST -H "Content-Type: application/json" -d \
    '{
        "username":'\"$2\"', "password":'\"$3\"',"loginProviderName": "tmos"
    }' \
    -k "https://$1/mgmt/shared/authn/login" |  jq ".token.token"`

    #DEBUG echo token result value
    ##echo "TokenString = $tokenString"

    OnboardID=`curl -s -k -H X-F5-Auth-Token:$tokenString -H "Content-Type: application/json" -d \
    '{
        "class": "DO",
        "declaration": {
            "schemaVersion": "1.29.0",
            "class": "Device",
            "async": true,
            "Common": {
                "class": "Tenant",
                "myProvision": {
                    "ltm": "nominal",
                    "class": "Provision",
                    "gtm": "nominal",
                    "asm": "nominal",
                    "avr": "nominal"
                },
                "myDns": {
                    "class": "DNS",
                    "nameServers": [
                        "8.8.8.8"
                    ]
                },
                "v3204-self": {
                    "class": "SelfIp",
                    "address": "10.130.204.'$6'/24",
                    "vlan": "vlan_3204",
                    "allowService": "default",
                    "trafficGroup": "traffic-group-local-only"
                },
                "v3209-self": {
                    "class": "SelfIp",
                    "address": "10.130.209.'$6'/24",
                    "vlan": "vlan_3209",
                    "allowService": "none",
                    "trafficGroup": "traffic-group-local-only"
                },
                "myNtp": {
                    "class": "NTP",
                    "servers": [
                        "time.google.com"
                    ],
                    "timezone": "UTC"
                },
                "root": {
                    "class": "User",
                    "userType": "root",
                    "newPassword": '\"$3\"',
                    "oldPassword": '\"$3\"'
                },
                "admin": {
                    "class": "User",
                    "shell": "bash",
                    "userType": "regular",
                    "password": '\"$3\"'
                },
                "hostname": '\"$4\"'
            }
        },
        "targetUsername": '\"$2\"',
        "targetTimeout": 900,
        "targetHost": '\"$5\"',
        "targetPassphrase": '\"$3\"',
        "targetPort": 443,
        "bigIqSettings": {
            "statsConfig": {
                "enabled": true
            },
            "conflictPolicy": "USE_BIGIQ",
            "deviceConflictPolicy": "USE_BIGIP",
            "failImportOnConflict": false,
            "versionedConflictPolicy": "KEEP_VERSION"
        }
    }' \
    "https://$1/mgmt/shared/declarative-onboarding"|jq -r '.id'`
}

while getopts "h" opt; do
    case $opt in
        h)
            echo ""
            echo "onboard-F5OS-velos-tenant.sh <newTenantIP> <lastOctectProductionInterfaces> <TargetF5OSname> <NewTenantFQDN> <DFG-Mgt-Net> <targetBIG-IQ>"
            echo "" 
            exit 1
            ;;
   esac
done
if [ -z "$1" ] && [ -z "$2" ] && [ -z "$3" ] && [ -z "$4" ] && [ -z "$5" ] && [ -z "$6" ]
then
    echo "No paramaters entered"
    echo ""
    echo "onboard-F5OS-velos-tenant.sh <newTenantIP> <lastOctectProductionInterfaces> <TargetF5OSname> <NewTenantFQDN> <DFG-Mgt-Net>"
    echo ""
    exit 1
fi

tenantName=`echo $4 | cut -f1 -d"."`
echo ""
echo "Using parameters"
echo "Tenant IP = $1"
echo "Last Octet for dataplane self-ip = $2"
echo "IP or hostname of F5OS appliance = $3"
echo "FQDN of tenant = $4"
echo "DFG for tenant Mgt network = $5"
echo "target BIG-IQ = $6"
echo "tenant Name = $tenantName"
echo ""

# Get username/password from a file
cred=`cat ../PW.txt`;user=`echo $cred | cut -d':' -f1`;pw=`echo $cred | cut -d':' -f2`
# Set sleep time
wait=60
echo ""
echo "Communicating with rSeries F5OS to create a Tenant"
echo "____________________________________________________"
echo ""
curl -k -X POST -u "$user:$pw" -H "X-Auth-Token: rctoken" -H "Content-Type: application/yang-data+json" https://$3:8888/restconf/data/f5-tenants:tenants -d \
'{
    "tenant": [
        {
            "name": "'$tenantName'",
            "config": {
                "image": "BIGIP-15.1.6-0.0.8.ALL-F5OS.qcow2.zip.bundle",
                "nodes": [
                    1
                ],
                "mgmt-ip": "'$1'",
                "gateway": "'$5'",
                "prefix-length": 24,
                "vlans": [
                    3204,
                    3209
                ],
                "vcpu-cores-per-node": 8,
                "memory": 29184,
                "cryptos": "enabled",
                "running-state": "deployed"
            }
        }
    ]
}'
echo ""
echo "Tenant Created and Starting"
echo "___________________________"
echo ""
status="check"
check='"Running"'
until [ "$status" = "$check" ]
do
        echo "Tenant not ready yet - wait $wait secs and check again"
        sleep $wait
        status=`curl -s -k -X GET -u "$user:$pw" -H "X-Auth-Token: rctoken" -H "Content-Type: application/yang-data+json" "https://$3:8888/restconf/data/f5-tenants:tenants/tenant=$tenantName"| jq '.[][0].state.status'`
done
echo ""
echo "Tenant is now marked as ready in Partition, will wait until it is contactable on the Mgt LAN"
echo ""
until ping -c 1 $1 >/dev/null 2>&1; do :;done
echo ""
echo "Tenant is available on Mgt LAN - wait $wait secs to ensure GUI is up"
echo "____________________________________________________________________"
echo ""
echo "Tenant Started"
echo "______________"
echo ""
echo ""
sleep $wait
echo "Reset Password on newly booted tenant"
echo "_____________________________________"
echo ""
status=`curl -sku admin:admin https://$1/mgmt/shared/authz/users/admin -X PATCH -H "Content-type: application/json" -d '{"oldPassword":"admin", "password":'\"$pw\"'}'|jq`
sleep 1
#echo "Get Token"
#echo "_________"
#tokenString=`curl -s -X POST -H "Content-Type: application/json" -d \
#'{
#	"username":"admin", "password":'\"$pw\"',"loginProviderName": "tmos"
#}' -k https://$1/mgmt/shared/authn/login |  jq -r ".token.token"`
#echo ""
#echo ""

echo "Moving to onboarding via BIG-IQ"
#Call function to onboard via IQ - values = <targetBIG-IQ> <username> <password> <FQDN> <targetBIG-IP>
onboard $6 $user $pw $4 $1 $2
echo "Onboard ID = $OnboardID"
echo ""
OnboardStatus="Initial"
check='"OK"'
until [ "$OnboardStatus" = "$check" ]
do
        echo "Waiting for onboard to complete - currently $OnboardStatus"
        sleep $wait
        tokenString=`curl -s -k -X POST -H "Content-Type: application/json" -d '{"username":'\"$user\"', "password":'\"$pw\"',"loginProviderName": "tmos"}' https://172.30.104.90/mgmt/shared/authn/login |  jq ".token.token"`
        OnboardStatus=`curl -s -H X-F5-Auth-Token:$tokenString -H "Content-Type: application/json" -k "https://172.30.104.90/mgmt/shared/declarative-onboarding/task/$OnboardID" | jq '.result.status'`
        if [ "$OnboardStatus" = '"ERROR"' ]
        then
            #Call function to onboard via IQ - values = <targetBIG-IQ> <username> <password> <FQDN> <targetBIG-IP>
            onboard $6 $user $pw $4 $1 $2
            echo "recieved an ERROR - will retry - new OnboardID=$OnboardID"
        fi
done
echo "Onboard complete - Ready to deploy services"


