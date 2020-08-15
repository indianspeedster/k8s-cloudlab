#!/bin/sh

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/kubespray-done ]; then
    exit 0
fi

logtstart "kubespray"

cd $OURDIR
if [ -e kubespray ]; then
    rm -rf kubespray
fi
git clone $KUBESPRAYREPO kubespray
if [ -n "$KUBESPRAYVERSION" ]; then
    cd kubespray && git checkout "$KUBESPRAYVERSION" && cd ..
fi

#
# Get Ansible and the kubespray python reqs installed.
#
maybe_install_packages ${PYTHON}
if [ $KUBESPRAYUSEVIRTUALENV -eq 1 ]; then
    if [ -e $KUBESPRAY_VIRTUALENV ]; then
	. $KUBESPRAY_VIRTUALENV/bin/activate
    else
	maybe_install_packages virtualenv

	mkdir -p $KUBESPRAY_VIRTUALENV
	virtualenv $KUBESPRAY_VIRTUALENV --python=${PYTHON}
	. $KUBESPRAY_VIRTUALENV/bin/activate
    fi
    $PIP install ansible==2.7
    $PIP install -r kubespray/requirements.txt
else
    maybe_install_packages software-properties-common ${PYTHON}-pip
    add-apt-repository --yes --update ppa:ansible/ansible
    maybe_install_packages ansible
    $PIP install -r kubespray/requirements.txt
fi

#
# Build the kubespray inventory file.  The basic builder changes our
# hostname, and we don't want that.  So do it manually.  We generate
# .ini format because it's much simpler to do in shell.
#
INVDIR=inventories/kubernetes
mkdir -p $INVDIR
cp -pR kubespray/inventory/sample/group_vars $INVDIR

INV=$INVDIR/inventory.ini
if [ $NODECOUNT -gt 1 ]; then
    echo '[all]' > $INV
    for node in $NODES ; do
	mgmtip=`getnodeip $node $MGMTLAN`
	dataip=`getnodeip $node $DATALAN`
	echo "$node ansible_host=$mgmtip ip=$dataip access_ip=$mgmtip" >> $INV
    done
    # The first 2 nodes are kube-master.
    echo '[kube-master]' >> $INV
    for node in `echo $NODES | cut -d ' ' -f-2` ; do
	echo "$node" >> $INV
    done
    # The first 3 nodes are etcd.
    echo '[etcd]' >> $INV
    for node in `echo $NODES | cut -d ' ' -f-3` ; do
	echo "$node" >> $INV
    done
    # The last 2--N nodes are kube-node, unless there is only one node.
    kubenodecount=2
    if [ "$NODES" = `echo $NODES | cut -d ' ' -f2` ]; then
	kubenodecount=1
    fi
    echo '[kube-node]' >> $INV
    for node in `echo $NODES | cut -d ' ' -f${kubenodecount}-` ; do
	echo "$node" >> $INV
    done
else
    # Just use localhost.
    cat <<EOF >> $INV
[all]
$HEAD ansible_host=127.0.0.1 ip=127.0.0.1 access_ip=127.0.0.1
[kube-master]
$HEAD
[etcd]
$HEAD
[kube-node]
$HEAD
EOF
fi
cat <<EOF >> $INV
[k8s-cluster:children]
kube-master
kube-node
EOF

#
# Get our basic configuration into place.
#
cat <<EOF >> $INVDIR/group_vars/all/all.yml
override_system_hostname: false
disable_swap: true
ansible_python_interpreter: $PYTHONBIN
ansible_user: root
kube_apiserver_node_port_range: 2000-36767
kubeadm_enabled: true
dns_min_replicas: 1
dashboard_enabled: true
EOF
if [ -n "${DOCKERVERSION}" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
docker_version: ${DOCKERVERSION}
EOF
fi
if [ -n "${KUBEVERSION}" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_version: ${KUBEVERSION}
EOF
fi
if [ -n "$KUBEFEATUREGATES" ]; then
    echo "kube_feature_gates: $KUBEFEATUREGATES" \
	>> $INVDIR/group_vars/all/all.yml
fi
if [ -n "$KUBELETCUSTOMFLAGS" ]; then
    echo "kubelet_custom_flags: $KUBELETCUSTOMFLAGS" \
	>> $INVDIR/group_vars/all/all.yml
fi
if [ -n "$KUBELETMAXPODS" -a $KUBELETMAXPODS -gt 0 ]; then
    echo "kubelet_max_pods: $KUBELETMAXPODS" \
        >> $INVDIR/group_vars/all/all.yml
fi

if [ "$KUBENETWORKPLUGIN" = "calico" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: calico
docker_iptables_enabled: true
EOF
elif [ "$KUBENETWORKPLUGIN" = "flannel" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: flannel
EOF
elif [ "$KUBENETWORKPLUGIN" = "weave" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: flannel
EOF
elif [ "$KUBENETWORKPLUGIN" = "canal" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: canal
EOF
fi

if [ "$KUBEENABLEMULTUS" = "1" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin_multus: true
multus_version: stable
EOF
fi

if [ "$KUBEPROXYMODE" = "iptables" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_proxy_mode: iptables
EOF
elif [ "$KUBEPROXYMODE" = "ipvs" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_proxy_mode: ipvs
EOF
fi

cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_pods_subnet: $KUBEPODSSUBNET
kube_service_addresses: $KUBESERVICEADDRESSES
EOF

#
# Enable helm, and stash its config bits in the right file.
#
grep -q helm_enabled $INVDIR/group_vars/all/all.yml
if [ $? -eq 0 ]; then
    HELM_INV_FILE=$INVDIR/group_vars/all/all.yml
else
    HELM_INV_FILE=$INVDIR/group_vars/k8s-cluster/addons.yml
fi
echo "helm_enabled: true" >> $HELM_INV_FILE
if [ -n "${HELMVERSION}" ]; then
    echo "helm_version: ${HELMVERSION}" >> $HELM_INV_FILE
fi

#
# Add a bunch of options most people will find useful.
#
DOCKOPTS='--insecure-registry={{ kube_service_addresses }}  {{ docker_log_opts }}'
if [ $NODECOUNT -gt 1 ]; then
    for lan in $DATALANS ; do
	DOCKOPTS="--insecure-registry=`getnodeip node-0 $lan`/`getnetmaskprefix $lan` $DOCKOPTS"
    done
fi
cat <<EOF >>$INVDIR/group_vars/k8s-cluster/k8s-cluster.yml
docker_dns_servers_strict: false
kubectl_localhost: true
kubeconfig_localhost: true
docker_options: "$DOCKOPTS"
metrics_server_enabled: true
kube_basic_auth: true
kube_api_pwd: "$ADMIN_PASS"
kube_users:
  admin:
    pass: "{{kube_api_pwd}}"
    role: admin
    groups:
      - system:masters
EOF
#kube_api_anonymous_auth: false

#
# Run ansible to build our kubernetes cluster.
#
ansible-playbook -i $INVDIR/inventory.ini \
    kubespray/cluster.yml -b -v

if [ ! $? -eq 0 ]; then
    echo "ERROR: ansible-playbook failed; check logfiles!"
    exit 1
fi

mkdir -p /root/.kube
mkdir -p ~$SWAPPER/.kube
cp -p $INVDIR/artifacts/admin.conf /root/.kube/config
cp -p $INVDIR/artifacts/admin.conf ~$SWAPPER/.kube/config
chown -R $SWAPPER ~$SWAPPER/.kube

kubectl wait pod -n kube-system --for=condition=Ready --all

#
# If helm is not installed, do that manually.  Seems that there is a
# kubespray bug (release-2.11) that causes this.
#
which helm
if [ ! $? -eq 0 -a -n "${HELM_VERSION}" ]; then
    wget https://storage.googleapis.com/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz
    tar -xzvf helm-${HELM_VERSION}-linux-amd64.tar.gz
    mv linux-amd64/helm /usr/local/bin/helm

    helm init --upgrade --force-upgrade
    kubectl create serviceaccount --namespace kube-system tiller
    kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
    kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'
    helm init --service-account tiller --upgrade
    while [ 1 ]; do
	helm ls
	if [ $? -eq 0 ]; then
	    break
	fi
	sleep 4
    done
    kubectl wait pod -n kube-system --for=condition=Ready --all
fi

logtend "kubespray"
touch $OURDIR/kubespray-done
