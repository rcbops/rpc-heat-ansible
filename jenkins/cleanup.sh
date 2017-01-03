#!/bin/bash

# add jenkins bin path for rack tool
PATH=$PATH:/opt/jenkins/bin

# pub cloud creds
. /opt/jenkins/rpc-heat-ansible-creds/openrc

# activate venv with heatclient
. /opt/jenkins/venvs/rpcheatansible/bin/activate

set -x

# This is also set in build.sh and must be changed there if changed here.
STACK_NAME=rpc-jenkins-$BUILD_NUMBER

BUILD_DELETED=1
if [[ ${DELETE_STACK:-yes} == yes ]]; then
  echo "===================================================="
  heat stack-delete $STACK_NAME 2>/dev/null

  for i in {1..30}; do
    sleep 30
    STACK_STATUS=`heat stack-list 2>/dev/null| awk '/ '$STACK_NAME' / { print $6 }'`
    BUILD_DELETED=`heat stack-list 2>/dev/null| awk '/ '$STACK_NAME' / { print $6 }' | wc -l`
    echo "===================================================="
    echo "Stack Status:        $STACK_STATUS"
    echo "Build Deleted:       $BUILD_DELETED"
    [[ $BUILD_DELETED -eq 0 ]] && break
    if [[ "$STACK_STATUS" != 'DELETE_IN_PROGRESS' ]]; then
      if [[ "$STACK_STATUS" == 'DELETE_FAILED' ]]; then
        NETWORK_ID=`heat resource-list $STACK_NAME 2>/dev/null| awk '/ OS::Neutron::Net / { print $4 }'`
        for PORT_ID in `rack networks port list --network-id $NETWORK_ID --fields id --no-header`; do
          rack networks port delete --id $PORT_ID
          sleep 20
        done
      fi
      heat stack-delete $STACK_NAME 2>/dev/null
    fi
  done
fi
