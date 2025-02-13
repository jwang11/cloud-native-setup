#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

CUR_DIR=$(pwd)
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

function print_usage_exit() {
	exit_code=${1:-0}
	cat <<EOT
Usage: $0 [subcommand]

Subcommands:

$(
		for cmd in "${!command_handlers[@]}"; do
			printf "\t%s:|\t%s\n" "${cmd}" "${command_help[${cmd}]:-Not-documented}"
		done | sort | column -t -s "|"
	)
EOT
	exit "${exit_code}"
}

function finish() {
	cd "${CUR_DIR}"
}
trap finish EXIT

function cluster_init() {
	#This only works with kubernetes 1.12+. The kubeadm.yaml is setup
	#to enable the RuntimeClass featuregate
	if [[ -d /var/lib/etcd ]]; then
		echo "/var/lib/etcd exists! skipping init."
		return
	fi
	sudo -E kubeadm init --config=./kubeadm.yaml

	rm -rf "${HOME}/.kube"
	mkdir -p "${HOME}/.kube"
	sudo cp -i /etc/kubernetes/admin.conf "${HOME}/.kube/config"
	sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

	# skip terminal check if CLRK8S_NOPROMPT is set
	skip="${CLRK8S_NOPROMPT:-}"
	if [[ -z "${skip}" ]]; then
		# If this an interactive terminal then wait for user to join workers
		if [[ -t 0 ]]; then
			read -p "Join other nodes. Press enter to continue"
		fi
	fi

	#Ensure single node k8s works
	if [ "$(kubectl get nodes | wc -l)" -eq 2 ]; then
		kubectl taint nodes --all node-role.kubernetes.io/master-
	fi
}

function kata() {
	KATA_VER=${1:-1.8.0-kernel-config}
	KATA_URL="https://github.com/kata-containers/packaging.git"
	KATA_DIR="8-kata"
	get_repo "${KATA_URL}" "${KATA_DIR}/overlays/${KATA_VER}"
	set_repo_version "${KATA_VER}" "${KATA_DIR}/overlays/${KATA_VER}/packaging"
	kubectl apply -k "${KATA_DIR}/overlays/${KATA_VER}"

}

function cni() {
	# note version is not semver
	CANAL_VER=${1:-v3.3}
	CANAL_URL="https://docs.projectcalico.org/$CANAL_VER/getting-started/kubernetes/installation/hosted/canal"
	CANAL_DIR="0-canal"

	# canal manifests are not kept in repo but in docs site so use curl
	mkdir -p "${CANAL_DIR}/overlays/${CANAL_VER}/canal"
	curl -o "${CANAL_DIR}/overlays/${CANAL_VER}/canal/canal.yaml" "$CANAL_URL/canal.yaml"
	curl -o "${CANAL_DIR}/overlays/${CANAL_VER}/canal/rbac.yaml" "$CANAL_URL/rbac.yaml"
	# canal doesnt pass kustomize validation
	kubectl apply -k "${CANAL_DIR}/overlays/${CANAL_VER}" --validate=false

}

function metrics() {
	METRICS_VER=${1:-v0.3.3}
	METRICS_URL="https://github.com/kubernetes-incubator/metrics-server.git"
	METRICS_DIR="1-core-metrics"
	get_repo "${METRICS_URL}" "${METRICS_DIR}/overlays/${METRICS_VER}"
	set_repo_version "${METRICS_VER}" "${METRICS_DIR}/overlays/${METRICS_VER}/metrics-server"
	kubectl apply -k "${METRICS_DIR}/overlays/${METRICS_VER}"

}

function create_pvc() {
	kubectl apply -f - <<HERE
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pv-claim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Mi
HERE

}

function storage() {
	#Start rook before any other component that requires storage
	ROOK_VER="${1:-v1.0.3}"
	ROOK_URL="https://github.com/rook/rook.git"
	ROOK_DIR=7-rook
	get_repo "${ROOK_URL}" "${ROOK_DIR}/overlays/${ROOK_VER}"
	set_repo_version "${ROOK_VER}" "${ROOK_DIR}/overlays/${ROOK_VER}/rook"
	kubectl apply -k "${ROOK_DIR}/overlays/${ROOK_VER}"
	# wait for the rook OSDs to run which means rooks should be ready
	while [[ $(kubectl get po --all-namespaces | grep -e 'osd.*Running.*' -c) -lt 1 ]]; do
		echo "Waiting for Rook OSD"
		sleep 60
	done
	# set default storage class to rook-ceph-block
	kubectl patch storageclass rook-ceph-block -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
	create_pvc
	# create and destroy pvc until successful
	while [[ $(kubectl get pvc test-pv-claim --no-headers | grep Bound -c) -ne 1 ]]; do
		sleep 30
		kubectl delete pvc test-pv-claim
		create_pvc
		sleep 10
	done

}

function monitoring() {
	PROMETHEUS_VER=${1:-v0.1.0}
	PROMETHEUS_URL="https://github.com/coreos/kube-prometheus.git"
	PROMETHEUS_DIR="4-kube-prometheus"
	get_repo "${PROMETHEUS_URL}" "${PROMETHEUS_DIR}/overlays/${PROMETHEUS_VER}"
	set_repo_version "${PROMETHEUS_VER}" "${PROMETHEUS_DIR}/overlays/${PROMETHEUS_VER}/kube-prometheus"
	kubectl apply -k "${PROMETHEUS_DIR}/overlays/${PROMETHEUS_VER}"

	while [[ $(kubectl get crd alertmanagers.monitoring.coreos.com prometheuses.monitoring.coreos.com prometheusrules.monitoring.coreos.com servicemonitors.monitoring.coreos.com >/dev/null 2>&1) || $? -ne 0 ]]; do
		echo "Waiting for Prometheus CRDs"
		sleep 2
	done

	#Expose the dashboards
	#kubectl --namespace monitoring port-forward svc/prometheus-k8s 9090 &
	#kubectl --namespace monitoring port-forward svc/grafana 3000 &
	#kubectl --namespace monitoring port-forward svc/alertmanager-main 9093 &
}

function dashboard() {
	DASHBOARD_VER=${1:-v2.0.0-beta2}
	DASHBOARD_URL="https://github.com/kubernetes/dashboard.git"
	DASHBOARD_DIR="2-dashboard"
	get_repo "${DASHBOARD_URL}" "${DASHBOARD_DIR}/overlays/${DASHBOARD_VER}"
	set_repo_version "${DASHBOARD_VER}" "${DASHBOARD_DIR}/overlays/${DASHBOARD_VER}/dashboard"
	kubectl apply -k "${DASHBOARD_DIR}/overlays/${DASHBOARD_VER}"
}

function ingres() {
	INGRES_VER=${1:-nginx-0.25.0}
	INGRES_URL="https://github.com/kubernetes/ingress-nginx.git"
	INGRES_DIR="5-ingres-lb"
	get_repo "${INGRES_URL}" "${INGRES_DIR}/overlays/${INGRES_VER}"
	set_repo_version "${INGRES_VER}" "${INGRES_DIR}/overlays/${INGRES_VER}/ingress-nginx"
	kubectl apply -k "${INGRES_DIR}/overlays/${INGRES_VER}"
}

function efk() {
	EFK_VER=${1:-v1.15.1}
	EFK_URL="https://github.com/kubernetes/kubernetes.git"
	EFK_DIR="3-efk"
	get_repo "${EFK_URL}" "${EFK_DIR}/overlays/${EFK_VER}"
	set_repo_version "${EFK_VER}" "${EFK_DIR}/overlays/${EFK_VER}/kubernetes"
	kubectl apply -k "${EFK_DIR}/overlays/${EFK_VER}"

}

function metallb() {
	METALLB_VER=${1:-v0.7.3}
	METALLB_URL="https://github.com/danderson/metallb.git"
	METALLB_DIR="6-metal-lb"
	get_repo "${METALLB_URL}" "${METALLB_DIR}/overlays/${METALLB_VER}"
	set_repo_version "${METALLB_VER}" "${METALLB_DIR}/overlays/${METALLB_VER}/metallb"
	kubectl apply -k "${METALLB_DIR}/overlays/${METALLB_VER}"

}

function miscellaneous() {

	# dashboard
	dashboard

	# EFK
	efk

	#Create an ingress load balancer
	ingres

	#Create a bare metal load balancer.
	#kubectl apply -f 6-metal-lb/metallb.yaml

	#The config map should be properly modified to pick a range that can live
	#on this subnet behind the same gateway (i.e. same L2 domain)
	#kubectl apply -f 6-metal-lb/example-layer2-config.yaml
}

function minimal() {
	cluster_init
	cni
	kata
	metrics
}

function all() {
	minimal
	storage
	monitoring
	miscellaneous
}

function get_repo() {
	local repo="${1}"
	local path="${2}"
	clone_dir=$(basename "${repo}" .git)
	[[ -d "${path}/${clone_dir}" ]] || git -C "${path}" clone "${repo}"

}

function set_repo_version() {
	local ver="${1}"
	local path="${2}"
	pushd "$(pwd)"
	cd "${path}"
	git fetch origin "${ver}"
	git checkout "${ver}"
	popd

}

declare -A command_handlers
command_handlers[init]=cluster_init
command_handlers[cni]=cni
command_handlers[minimal]=minimal
command_handlers[all]=all
command_handlers[help]=print_usage_exit
command_handlers[storage]=storage
command_handlers[monitoring]=monitoring
command_handlers[metallb]=metallb

declare -A command_help
command_help[init]="Only inits a cluster using kubeadm"
command_help[cni]="Setup network for running cluster"
command_help[minimal]="init + cni +  kata + metrics"
command_help[all]="minimal + storage + monitoring + miscellaneous"
command_help[help]="show this message"

cd "${SCRIPT_DIR}"

cmd_handler=${command_handlers[${1:-none}]:-unimplemented}
if [ "${cmd_handler}" != "unimplemented" ]; then
	if [ $# -eq 1 ]; then
		"${cmd_handler}"
		exit $?
	fi

	"${cmd_handler}" "$2"

else
	print_usage_exit 1
fi
