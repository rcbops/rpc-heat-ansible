#!/bin/bash

set -x

# add jenkins bin path for rack tool
PATH=$PATH:/opt/jenkins/bin

# pub cloud creds
. /opt/jenkins/rpc-heat-ansible-creds/openrc

# activate venv with heatclient
. /opt/jenkins/venvs/rpcheatansible/bin/activate

# This is also set in cleanup.sh and must be changed there if changed here.
STACK_NAME=rpc-jenkins-$BUILD_NUMBER

# Blocking stack create
heat stack-create \
  -t 600\
  -f templates/rpc-${HEAT_TEMPLATE}.yml\
  -e /opt/jenkins/rpc-heat-ansible-creds/user-maas-credentials.yml\
  -P ansible_tags="$RPC_HEAT_ANSIBLE_TAGS"\
  -P ansible_repo="https://github.com/hughsaunders/ansible"\
  -P ansible_version="ssh_retry"\
  -P rpc_release=$RPC_RELEASE\
  -P rpc_heat_ansible_playbook="$RPC_HEAT_ANSIBLE_PLAYBOOK"\
  -P rpc_heat_ansible_release=$RPC_HEAT_ANSIBLE_RELEASE\
  -P rpc_heat_ansible_repo=$RPC_HEAT_ANSIBLE_REPO\
  -P apply_patches=$APPLY_PATCHES\
  -P deploy_retries=$DEPLOY_RETRIES\
  $STACK_NAME\
  --poll 120

BUILD_FAILED=0

STACK_STATUS=`heat stack-list | awk '/ '$STACK_NAME' / { print $6 }'`
RESOURCES_FAILED=`heat resource-list $STACK_NAME | grep CREATE_FAILED | wc -l`
SWIFT_SIGNAL_FAILED=`heat event-list $STACK_NAME | grep SwiftSignalFailure | wc -l`
if [[ "$STACK_STATUS" == 'CREATE_FAILED' || $RESOURCES_FAILED -gt 0 || "$STACK_STATUS" =~ ^[[:space:]]*$ ]]; then
  BUILD_FAILED=1
fi
echo "===================================================="
echo "Stack Status:        $STACK_STATUS"
echo "Build Failed:        $BUILD_FAILED"
echo "Resources Failed:    $RESOURCES_FAILED"
echo "Swift Signal Failed: $SWIFT_SIGNAL_FAILED"

if [[ $BUILD_FAILED -eq 1 ]]; then
  echo "===================================================="
  heat stack-list 2>/dev/null
  echo "===================================================="
  heat resource-list $STACK_NAME  2>/dev/null| grep -v CREATE_COMPLETE
  echo "===================================================="
  heat event-list $STACK_NAME 2>/dev/null
fi

# Get infra1 ip and key
INFRA1_IP=`heat output-show $STACK_NAME server_infra1_ip -F raw 2>/dev/null`

if [[ $INFRA1_IP == None ]]; then
#TODO: Get name from nova if heat output is None
INFRA1_NAME="$(heat stack-show rpc-jenkins-278 |awk '$2~/^id$/{print $4}' |cut -d- -f1)-infra1"
INFRA1_IP="$(nova show $INFRA1_NAME |awk '/accessIPv4/{print $4}' )"
fi

heat output-show $STACK_NAME private_key -F raw > $STACK_NAME.pem 2>/dev/null
chmod 400 $STACK_NAME.pem

mkdir -p artifacts
if [[ $BUILD_FAILED == 0 && ${RPC_HEAT_ANSIBLE_TAGS} =~ "tempest" ]]; then
  # Execute Tempest
  ssh \
    -i $STACK_NAME.pem \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    root@$INFRA1_IP \
    "sudo /usr/bin/lxc-attach -n \$(sudo /usr/bin/lxc-ls |grep utility) -- /bin/bash -c \"RUN_TEMPEST_OPTS='--serial' /opt/openstack_tempest_gate.sh ${TEMPEST_TESTS}\""

  # Set build status to failed if tempest failed.
  BUILD_FAILED=$?

  # Retrieve tempest results
  # Tempest executes in the utility container but copies its
  # results to /var/log/utility which is bind mounted to the host.
  scp \
    -i $STACK_NAME.pem \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    "root@$INFRA1_IP:/openstack/log/*utility*/*.xml" artifacts
fi

# Retrieve Log files
echo "===================================================="
scp -i $STACK_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$INFRA1_IP:/opt/cloud-training/*.log artifacts
scp -i $STACK_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$INFRA1_IP:/opt/cloud-training/*.err artifacts
scp -i $STACK_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$INFRA1_IP:/var/log/cloud-init-output.log artifacts
echo "===================================================="

if [[ $BUILD_FAILED -eq 1 && $SWIFT_SIGNAL_FAILED -gt 0 || ( $BUILD_FAILED -eq 0 ) ]]; then
  echo "Build Failure Analyzer Extractions:"
  echo ""
  grep -e "fatal: \[" -e "failed: \[" -e "msg: " -e "\.\.\.ignoring" -e "stderr: " -e "stdout: " -e "OSError: " -e "UndefinedError: " -e ", W:" -e ", E:" -e "PLAY" -e " Entity:" -e " Check:" -e " Alarm:" runcmd-bash.log deploy.sh.log
fi

# Stack deletion has been moved to cleanup.sh so it can be run as a post build action.
[[ ${RUN_CLEANUP_FROM_BUILD:-no} == yes ]] && $(dirname $0)/cleanup.sh

exit $BUILD_FAILED
