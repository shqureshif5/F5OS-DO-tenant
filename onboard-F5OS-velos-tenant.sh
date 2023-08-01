#!/bin/bash
# onboard-F5OS-appliance-tenant.sh will deploy a tenant on VELOS 
# and then perform the necessary onboarding directly. 
#
# The steps the scripts takes are as follows
# . Communicate with VELOS
# . Create a Tenant 
# .. Wait for Tenant to become available - currently no simple way to interrogate availability so a PING of the mgt address is what I do
# . Reset the Password
# . Upload the DO rpm to the new Tenant
# . Perform the Declarative Onboarding
# . Script complete and ready for AS3 deployment or Appliance migration
#
# For simplicity, I have created a local password file, for the script to connect to. So the password is not in this script. ../PW.txt
#
# Please ensure the correct vlans are in use by the script. At the moment this is hardcoded in the script. See the API post to the
# newly created BIG-IP. The vlans will need to be set accordingly. This should be added as a parameter used by the execution of the script.
#
# You need the declarative onboarding rpm to be available for the BIG-IP to be deployed.
#

while getopts "h" opt; do
    case $opt in
        h)
            echo ""
            echo "onboard-F5OS-velos-tenant.sh <newTenantIP> <lastOctectProductionInterfaces> <TargetF5OSname> <NewTenantFQDN> <DFG-Mgt-Net>"
            echo "" 
            exit 1
            ;;
   esac
done
if [ -z "$1" ] && [ -z "$2" ] && [ -z "$3" ] && [ -z "$4" ]
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
echo "tenant Name = $tenantName"
echo ""

# Get username/password from a file
cred=`cat ../PW.txt`;user=`echo $cred | cut -d':' -f1`;pw=`echo $cred | cut -d':' -f2`
# Set sleep time
wait=60
echo ""
echo "Communicating with VELOS F5OS to create a Tenant"
echo "____________________________________________________"
echo ""
curl -k -X POST -u "$user:$pw" -H "X-Auth-Token: rctoken" -H "Content-Type: application/yang-data+json" https://$3:8888/restconf/data/f5-tenants:tenants -d \
'{
    "tenant": [
        {
            "name": "'$tenantName'",
            "config": {
                "image": "BIGIP-15.1.8-0.0.7.T4-F5OS.qcow2.zip.bundle",
                "nodes": [
                    1
                ],
                "mgmt-ip": "'$1'",
                "gateway": "'$5'",
                "prefix-length": 24,
                "vlans": [
                    3040,
                    3041,
                    3042,
                    3043,
                    3044,
                    3045,
                    3046,
                    3047,
                    3048,
                    3049
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
        status=`curl -s -k -X GET -u "$user:$pw" -H "X-Auth-Token: rctoken" -H "Content-Type: application/yang-data+json" https://$3:8888/restconf/data/f5-tenants:tenants/tenant=$tenantName| jq '.[][0].state.status'`
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
echo "Get Token"
echo "_________"
tokenString=`curl -s -X POST -H "Content-Type: application/json" -d \
'{
	"username":"admin", "password":'\"$pw\"',"loginProviderName": "tmos"
}' -k https://$1/mgmt/shared/authn/login |  jq -r ".token.token"`
echo ""
echo "Token = $tokenString"
echo "____________________"
echo ""
echo ""
echo "Update Onboarding rpm on Tenant"
echo "_______________________________"
echo ""
FN=f5-declarative-onboarding-1.32.0-3.noarch.rpm
CREDS=admin:$pw
IP=$1
cd $HOME/Downloads
LEN=$(wc -c $FN | cut -f 2 -d ' ')
status=`curl -s -ku $CREDS https://$IP/mgmt/shared/file-transfer/uploads/$FN -H 'Content-Type: application/octet-stream' -H "Content-Range: 0-$((LEN - 1))/$LEN" -H "Content-Length: $LEN" -H 'Connection: keep-alive' --data-binary @$FN`
DATA="{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/$FN\"}"
status=`curl -s -ku $CREDS "https://$IP/mgmt/shared/iapp/package-management-tasks" -H "Origin: https://$IP" -H 'Content-Type: application/json;charset=UTF-8' --data $DATA`
cd $HOME/Documents/Scripts/API-F5OS/F5OS-DO-tenant
echo ""
echo "Pushed Declarative Onboarding to tenant"
echo "_______________________________________"
echo ""
sleep $wait
#echo ""
#echo "Send onboard details"
#echo "____________________"
#echo ""
curl -s -X POST -u admin:$pw -H "Content-Type: application/json" -d \
'{
    "schemaVersion": "1.0.0",
    "class": "Device",
    "async": true,
    "Common": {
        "class": "Tenant",
        "mySystem": {
            "class": "System",
            "hostname": "'$4'",
            "cliInactivityTimeout": 1200,
            "consoleInactivityTimeout": 1200,
            "autoPhonehome": false
        },
        "myDns": {
            "class": "DNS",
            "nameServers": [
                "8.8.8.8"
            ],
            "search": [
                "google.com"
            ]
        },
        "myNtp": {
            "class": "NTP",
            "servers": [
                "time.google.com"
            ],
            "timezone": "Europe/London"
        },
        "root": {
            "class": "User",
            "userType": "root",
            "oldPassword": "'$pw'",
            "newPassword": "'$pw'"
        },
        "admin": {
            "class": "User",
            "userType": "regular",
            "password": "'$pw'",
            "shell": "bash"
        },
        "myProvisioning": {
            "class": "Provision",
            "ltm": "nominal"
        },
        "v3041-self": {
            "class": "SelfIp",
            "address": "10.130.241.'$2'/24",
            "vlan": "vlan_3041",
            "allowService": "default",
            "trafficGroup": "traffic-group-local-only"
        },
        "v3042-self": {
            "class": "SelfIp",
            "address": "10.130.242.'$2'/24",
            "vlan": "vlan_3042",
            "allowService": "none",
            "trafficGroup": "traffic-group-local-only"
        }
    }
}' \
-k "https://$1/mgmt/shared/declarative-onboarding" >/dev/null

echo ""
curl -sku admin:$pw https://$1/mgmt/shared/declarative-onboarding/ |jq


