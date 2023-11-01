#!/bin/bash
#set -x
# Copyright (c) 2021 Red Hat, Inc.
# Copyright Contributors to the Open Cluster Management project


BASE_COLLECTION_PATH=${BASE_COLLECTION_PATH:-"/must-gather"}
mkdir -p ${BASE_COLLECTION_PATH}

# Locally the script will fail due to /must-gather being a Read-only file directory.
if [ $? -ne 0 ]; then
  echo -e "Failed to create base collection directory: $BASE_COLLECTION_PATH (defaulting path to: \"./must-gather\")."

  BASE_COLLECTION_PATH="./must-gather"
  if [[ -d $BASE_COLLECTION_PATH ]]; then
    echo -e "Directory \"$BASE_COLLECTION_PATH\" already exists. Setting new path to prevent override: \"$BASE_COLLECTION_PATH-$(date +%Y-%m-%d-%s)\"."
    BASE_COLLECTION_PATH="$BASE_COLLECTION_PATH-$(date +%Y-%m-%d-%s)"
  fi

  mkdir -p $BASE_COLLECTION_PATH && echo -e
fi

# Set a file path for the gather managed clusters.
MANAGED_CLUSTER_FILE_PATH=$BASE_COLLECTION_PATH/gather-managed.log

HUB_CLUSTER=false
SPOKE_CLUSTER=false
MCE_NAME=""
OPERATOR_NAMESPACE=""
DEPLOYMENT_NAMESPACE=""

HC_NAME=""
HC_NAMESPACE="clusters" # default hosted cluster namespace

check_managed_clusters() {
    touch $MANAGED_CLUSTER_FILE_PATH
    echo -e "The list of managed clusters that are configured on this hub:" 2>&1 | tee -a $MANAGED_CLUSTER_FILE_PATH

    # These calls will change with new API
    oc get managedclusters --all-namespaces 2>&1 | tee -a $MANAGED_CLUSTER_FILE_PATH

    # to capture details in the managed cluster namespace to debug hive issues
    # refer https://github.com/open-cluster-management/backlog/issues/2682
    local mc_namespaces=$(oc get managedclusters --all-namespaces --no-headers=true -o custom-columns="NAMESPACE:.metadata.name")

    for mcns in ${mc_namespaces}; do
      oc adm inspect ns/"$mcns" --dest-dir=$BASE_COLLECTION_PATH
    done
}

check_if_hub () {
    MCE_NAME=$(oc get multiclusterengines.multicluster.openshift.io --all-namespaces --no-headers=true | awk '{ print $1 }')
    if [[ -n "$MCE_NAME" ]];
    then
      echo -e "Detected MCE resource: \"$MCE_NAME\" on current cluster. This cluster has been verified as a hub cluster.\n"
      HUB_CLUSTER=true
      OPERATOR_NAMESPACE=$(oc get pod -l control-plane=backplane-operator --all-namespaces --no-headers=true | head -n 1 | awk '{ print $1 }')
      DEPLOYMENT_NAMESPACE=$(oc get mce "$MCE_NAME" -o jsonpath='{.spec.targetNamespace}')
    else
      echo -e "No MCE resource detected on the current cluster. This is not a hub cluster (Previous errors can be safely ignored).\n"
    fi
}

check_if_spoke () {
    if oc get crd klusterlets.operator.open-cluster-management.io;
    then
      echo -e "The current cluster has klusterlets.operator.open-cluster-management.io crd, it is a spoke cluster.\n"
      SPOKE_CLUSTER=true
    else
      echo -e "The current cluster does not have klusterlets.operator.open-cluster-management.io crd, it is not a spoke cluster.\n"
    fi
}

check_if_hypershift () {
    # get the hosted cluster name and optionally namespace
    while [ "$1" != "" ]; do
        FLAG=`echo $1 | awk -F= '{print $1}'`
        VALUE=`echo $1 | awk -F= '{print $2}'`
        case $FLAG in
            hosted-cluster-name)
                HC_NAME=$VALUE
                ;;
            hosted-cluster-namespace)
                HC_NAMESPACE=$VALUE
                ;;
            *)
                echo "ERROR: unknown parameter \"$FLAG\""
                exit 1
                ;;
        esac
        shift
    done
}

gather_spoke () {
    oc adm inspect klusterlets.operator.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clusterclaims.cluster.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    KLUSTERLETS_NAMES=$(oc get klusterlets.operator.open-cluster-management.io --no-headers=true -o custom-columns="NAME:.metadata.name")
    for name in ${KLUSTERLETS_NAMES};
    do
      local agent_namespace
      local mode=$(oc get klusterlets.operator.open-cluster-management.io "$name" -o jsonpath='{.spec.deployOption.mode}')
      echo "klusterlet $name is deployed in $mode mode"
      if [ "$mode" = 'Hosted' ];
      then
        agent_namespace=$name
      else
        agent_namespace=$(oc get klusterlets.operator.open-cluster-management.io klusterlet -o jsonpath='{.spec.namespace}')
      fi

      echo "klusterlet name: $name, agent namespace: $agent_namespace"
      oc adm inspect ns/"$agent_namespace" --dest-dir=$BASE_COLLECTION_PATH
      oc adm inspect ns/"${agent_namespace}-addon" --dest-dir=$BASE_COLLECTION_PATH
    done

    oc adm inspect ns/openshift-operators --dest-dir=$BASE_COLLECTION_PATH # gatekeeper operator will be installed in this ns in production
}

extract_hypershift_cli() {
  oc get namespace hypershift

  if [ $? -ne 0 ];
  then
    echo "hypershift namespace not found"
    return 1
  fi

  # Get a running hypershift operator pod
  oc project hypershift
  HO_POD_NAME=$(oc get pod --no-headers=true --field-selector=status.phase=Running -l app=operator -o custom-columns="NAME:.metadata.name" | head -n 1)

  if [[ -n $HO_POD_NAME ]];
  then
    echo "Found a running hypershift operator pod: \"$HO_POD_NAME\""
  else
    echo "No running hypershift operator pod found."
    return 1
  fi

  # Extract the hypershift CLI from the hypershift operator pod
  oc rsync ${HO_POD_NAME}:/usr/bin/hypershift /tmp
  chmod 755 /tmp/hypershift
  return 0
}

dump_hostedcluster() {
  if [[ -z $HC_NAME ]];
  then
    echo "Hosted cluster name was not provided. Skip collecting hosted cluster must-gather."
    return 0
  fi

  HC=$(oc get hostedcluster $HC_NAME -n $HC_NAMESPACE)
  if [[ -z $HC ]];
  then
    echo "ERROR: hosted cluster \"$HC_NAME\" not found in \"$HC_NAMESPACE\" namespace"
    return 1
  fi

  if ! extract_hypershift_cli;
  then
    echo "Failed to extract the hypershift CLI binary."
    return 1
  fi

  echo "Collecting must-gather for hosted cluster \"$HC_NAME\" in namespace \"$HC_NAMESPACE\""
  /tmp/hypershift dump cluster --dump-guest-cluster --artifact-dir $BASE_COLLECTION_PATH --name $HC_NAME --namespace $HC_NAMESPACE
}

# This is not supported yet
gather_all_hostedclusters() {
  oc adm inspect pod -n open-cluster-management-agent-addon --dest-dir=$BASE_COLLECTION_PATH
  oc adm inspect pod -n hypershift --dest-dir=$BASE_COLLECTION_PATH

  oc get namespace hypershift

  if [ $? -ne 0 ];
  then
    echo "hypershift namespace not found"
    return
  fi

  HC_NAMESPACES=$(oc get hostedcluster --all-namespaces --no-headers=true -o custom-columns=NAMESPACE:.metadata.namespace | sort -u)

  if [[ -n $HC_NAMESPACES ]];
  then
    # Get a running hypershift operator pod
    oc project hypershift
    HO_POD_NAME=$(oc get pod --no-headers=true --field-selector=status.phase=Running -l app=operator -o custom-columns="NAME:.metadata.name" | head -n 1)

    if [[ -n $HO_POD_NAME ]];
    then
      echo "Found a running hypershift operator pod: \"$HO_POD_NAME\""
    else
      echo "No running hypershift operator pod found."
      return
    fi

    # Extract the hypershift CLI from the hypershift operator pod
    oc rsync ${HO_POD_NAME}:/usr/bin/hypershift /tmp
    chmod 755 /tmp/hypershift

    for hc_namespace in ${HC_NAMESPACES};
    do
      HC_LIST=$(oc get hostedcluster -n $hc_namespace --no-headers=true -o custom-columns="NAME:.metadata.name")
      if [[ -n $HC_LIST ]];
      then
          for hc in ${HC_LIST};
          do
            echo "Collecting must-gather for hosted cluster $hc"
            /tmp/hypershift dump cluster --dump-guest-cluster --artifact-dir $BASE_COLLECTION_PATH --name $hc --namespace $hc_namespace
          done
      else
        echo "No hosted cluster found in $hc_namespace namespace."
        return
      fi
    done
  else
      echo "No hosted cluster found."
      return
  fi
}

gather_hub() {
    check_managed_clusters

    # If the namespaces are different, capture the pods in each namespace.
    if [[ $DEPLOYMENT_NAMESPACE != $OPERATOR_NAMESPACE ]]; then
      echo -e "\nMCE target and operator namespace are different"

      echo -e "Listing pods in $OPERATOR_NAMESPACE namespace:" >> ${BASE_COLLECTION_PATH}/gather-mce.log
      oc get pods -n "${OPERATOR_NAMESPACE}" >> ${BASE_COLLECTION_PATH}/gather-mce.log

      echo -e "\nListing pods in $DEPLOYMENT_NAMESPACE namespace:" >> ${BASE_COLLECTION_PATH}/gather-mce.log
      oc get pods -n "${DEPLOYMENT_NAMESPACE}" >> ${BASE_COLLECTION_PATH}/gather-mce.log

      oc adm inspect ns/"${OPERATOR_NAMESPACE}" --dest-dir=$BASE_COLLECTION_PATH
      oc adm inspect ns/"${DEPLOYMENT_NAMESPACE}" --dest-dir=$BASE_COLLECTION_PATH

    else
      echo -e "Listing pods in $OPERATOR_NAMESPACE namespace:" >> ${BASE_COLLECTION_PATH}/gather-mce.log

      oc get pods -n "${OPERATOR_NAMESPACE}" >> ${BASE_COLLECTION_PATH}/gather-mce.log
      oc adm inspect ns/"${OPERATOR_NAMESPACE}" --dest-dir=$BASE_COLLECTION_PATH
    fi

    echo -e "\nClusterServiceVersion for MCE:" >> ${BASE_COLLECTION_PATH}/gather-mce.log
    oc get csv -n "${OPERATOR_NAMESPACE}" >> ${BASE_COLLECTION_PATH}/gather-mce.log

    echo -e "\nListing pods in open-cluster-management-agent-addon namespace:" >> ${BASE_COLLECTION_PATH}/gather-mce.log
    oc get pods -n open-cluster-management-agent-addon >> ${BASE_COLLECTION_PATH}/gather-mce.log

    echo -e "\nListing pods in hypershift namespace:" >> ${BASE_COLLECTION_PATH}/gather-mce.log
    oc get pods -n hypershift >> ${BASE_COLLECTION_PATH}/gather-mce.log

    oc adm inspect ns/open-cluster-management-hub --dest-dir=$BASE_COLLECTION_PATH
    # request from https://bugzilla.redhat.com/show_bug.cgi?id=1853485
    oc get proxy -o yaml > ${BASE_COLLECTION_PATH}/gather-proxy-mce.log
    oc adm inspect ns/hive --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect multiclusterengines.multicluster.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect hiveconfigs.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    oc adm inspect clusterserviceversions.operators.coreos.com --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect subscriptions.operators.coreos.com --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect installplans.operators.coreos.com --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect operatorgroups.operators.coreos.com --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    oc adm inspect baremetalhosts.metal3.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect preprovisioningimages.metal3.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    oc adm inspect placementdecisions.cluster.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect placements.cluster.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clusterdeployments.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect syncsets.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clusterimagesets.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect machinesets.machine.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clustercurators.cluster.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clusterpools.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clusterclaims.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect machinepools.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH


    oc adm inspect managedclusterviews.view.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedclusteractions.action.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect manifestworks.work.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedclusters.cluster.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedclusterinfos.internal.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clustermanagers.operator.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedserviceaccounts.authentication.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedclustersets.cluster.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedclustersetbindings.cluster.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedclusterimageregistries.imageregistry.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH


    oc adm inspect validatingwebhookconfigurations.admissionregistration.k8s.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect mutatingwebhookconfigurations.admissionregistration.k8s.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    oc adm inspect discoveredclusters.discovery.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect discoveryconfigs.discovery.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    oc adm inspect clustermanagementaddons.addon.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect managedclusteraddons.addon.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect addondeploymentconfigs.addon.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect addontemplates.addon.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    oc adm inspect klusterletconfigs.config.open-cluster-management.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    oc adm inspect ns/openshift-monitoring --dest-dir=$BASE_COLLECTION_PATH

    # Topology Aware Lifecycle Manager CRs
    oc adm inspect ns/openshift-operators --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect clustergroupupgrades.ran.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    # Inspect Assisted-installer CRs
    oc adm inspect agent.agent-install.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect agentclassification.agent-install.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect agentclusterinstall.extensions.hive.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect agentserviceconfig.agent-install.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect hypershiftagentserviceconfig.agent-install.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect infraenv.agent-install.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH
    oc adm inspect nmstateconfig.agent-install.openshift.io --all-namespaces --dest-dir=$BASE_COLLECTION_PATH

    # OpenShift console plug-in enablement
    oc adm inspect consoles.operator.openshift.io --dest-dir=$BASE_COLLECTION_PATH

    # Capture metal3 logs if the customer has at least one baremetalhost cr which indicates that bmc is being used to create new clusters
    if oc get baremetalhosts.metal3.io --all-namespaces &> /dev/null; then
      oc adm inspect ns/openshift-machine-api --dest-dir=$BASE_COLLECTION_PATH
    fi
}

check_if_hub
check_if_spoke
check_if_hypershift "$@"

if $HUB_CLUSTER; then
  echo "Start to gather information for hub"
  gather_hub
  dump_hostedcluster
fi

if $SPOKE_CLUSTER; then
  echo "Start to gather information for spoke"
  gather_spoke
fi

exit 0

}