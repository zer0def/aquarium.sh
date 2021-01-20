#!/bin/bash -e
[ "${SCRIPT_DEBUG:-1}" -eq 0 ] && set -x && export KUBEDEE_DEBUG=1
MYDIR="$(dirname "$(readlink -f "${0}")")"

DEFAULT_PROXY_REGISTRIES=(ghcr.io k8s.gcr.io gcr.io quay.io "registry.opensource.zalan.do")
REGISTRY_PROXY_REPO="${REGISTRY_PROXY_REPO:="rpardini/docker-registry-proxy:0.6.3"}"

usage(){
  local MYNAME="$(basename "${0}")"
  cat >&2 <<EOF
${MYNAME%.*} - Openstack+Ceph-on-K8S dev environment on LXD VMs via Kubedee

Usage: ${0} [options] <up|down>

Options:
  -N <name>, --name <name>              cluster name
                                        (default: ${CLUSTER_NAME}, env: CLUSTER_NAME)
  -n <num>, --num <num>                 number of workers
                                        (default: ${NUM_WORKERS}, env: NUM_WORKERS)
  -V <tag>, --tag <tag>                 Kubernetes version to use
                                        (default: ${K8S_VERSION}, env: K8S_VERSION)
  -s <pool>, --storage-pool <pool>      LXD storage pool to use for the K8S cluster
                                        (default: ${LXD_STORAGE_POOL}, env: LXD_STORAGE_POOL)
  -o <tag>, --openstack-version <tag>   Openstack version to deploy
                                        (default: ${OS_VERSION}, env: OS_VERSION)
  -b <base>, --base-image <base>        base LOCI image to use for Openstack
                                        images (default: ${BASE_IMAGE}, env: BASE_IMAGE)
  -c <mem>, --controller-mem <mem>      memory to allocate towards K8S controller
                                        (default: ${CONTROLLER_MEMORY_SIZE}, env: CONTROLLER_MEMORY_SIZE)
  -w <mem>, --worker-mem <mem>          memory to allocate per K8S worker
                                        (default: ${WORKER_MEMORY_SIZE}, env: WORKER_MEMORY_SIZE)
  -C <semver>, --ceph-version <semver>  Ceph package version to use
                                        (default: ${CEPH_VERSION}, env CEPH_VERSION)
EOF
  exit 1
}

declare -A STABLE_VERSION_REQUIREMENTS=(
  ['victoria']='neutron-lib<2.7.0'
)

#until kubectl wait --for condition=complete job "k3d-${CLUSTER_NAME}-server"; do sleep 1; done 2>/dev/null
setup_helm(){
  declare -A HELM_PLUGINS=(
    ['https://github.com/hypnoglow/helm-s3']="v0.9.2"
    ['https://github.com/zendesk/helm-secrets']="v2.0.2"
    ['https://github.com/aslafy-z/helm-git']="v0.8.1"
    ['https://github.com/databus23/helm-diff']="v3.1.3"
    ['https://github.com/hayorov/helm-gcs']="0.3.6"
  )
  helm version --template '{{.Version}}' | grep -E '^v3\.' || TILLER_SERVICE_ACCOUNT="tiller"
  # Helm v2: `helm version -c --template '{{.Client.SemVer}}'`
  [ -n "${TILLER_SERVICE_ACCOUNT}" ] && HELM_PLUGINS['https://github.com/rimusz/helm-tiller']="v0.9.3" && install_tiller

  echo "Installing Helm plugins…"
  for i in "${!HELM_PLUGINS[@]}"; do helm plugin install "${i}" --version "${HELM_PLUGINS[${i}]}" ||:; done
}

install_tiller(){
  echo "Installing Tiller…"
  kubectl apply -f- <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${TILLER_SERVICE_ACCOUNT}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${TILLER_SERVICE_ACCOUNT}-cluster-admin-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: ${TILLER_SERVICE_ACCOUNT}
  namespace: kube-system
EOF

  helm init --upgrade --service-account "${TILLER_SERVICE_ACCOUNT}"
  until kubectl -n kube-system wait --for condition=available deploy tiller-deploy; do sleep 1; done 2>/dev/null
}

registry_proxy(){
  local REGISTRIES="${PROXY_REGISTRIES:=${DEFAULT_PROXY_REGISTRIES[@]}}" AUTH_REGISTRIES="${PROXY_REGISTRIES_AUTH}" TARGET_FILE="${1}"
  docker run -d \
    --name "${REGISTRY_PROXY_HOSTNAME}" \
    -v "${REGISTRY_PROXY_HOST_PATH}:/docker_mirror_cache" \
    -e "REGISTRIES=${REGISTRIES}" \
    -e "AUTH_REGISTRIES=${AUTH_REGISTRIES}" \
    -e "ENABLE_MANIFEST_CACHE=true" \
    -e 'MANIFEST_CACHE_PRIMARY_REGEX=.*' \
    -e 'MANIFEST_CACHE_PRIMARY_TIME=6h' \
    -e 'MANIFEST_CACHE_SECONDARY_REGEX=.*' \
    -e 'MANIFEST_CACHE_SECONDARY_TIME=6h' \
    -e 'MANIFEST_CACHE_DEFAULT_TIME=6h' \
    "${REGISTRY_PROXY_REPO}" &>/dev/null
  docker exec "${REGISTRY_PROXY_HOSTNAME}" /bin/sh -c 'until test -f /ca/ca.crt; do sleep 1; done; cat /ca/ca.crt' >> "${TARGET_FILE}"
}

populate_local_registry(){
  local LOCI_LXD_LOCATION="/tmp/loci" TMP_SYSTEMD_SVC="$(mktemp)" OSH_IMG_LXD_LOCATION="/tmp/openstack-helm-images"
  local BUILDER_HOST="kubedee-${CLUSTER_NAME}-controller"
  #local BUILDER_HOST="$(lxc ls -cn --format csv | awk "/^kubedee-${CLUSTER_NAME}-worker-/" | head -n1)"

  cat <<EOF >"${TMP_SYSTEMD_SVC}"
[Service]
Environment="HTTP_PROXY=http://${REGISTRY_PROXY_ADDRESS}:3128/"
Environment="HTTPS_PROXY=http://${REGISTRY_PROXY_ADDRESS}:3128/"
Environment="NO_PROXY=${LOCAL_REGISTRY_HOST}"
EOF

  lxc file push -pr "${MYDIR}/../images/loci" "${BUILDER_HOST}${LOCI_LXD_LOCATION%/*}"
  lxc file push -pr "${MYDIR}/../images/openstack-helm-images" "${BUILDER_HOST}${OSH_IMG_LXD_LOCATION%/*}"
  lxc file push -pr "${TMP_SYSTEMD_SVC}" "${BUILDER_HOST}/etc/systemd/system/docker.service.d/registry-proxy.conf"
  lxc exec "${BUILDER_HOST}" -- /bin/bash -ex <<EOF
zypper in -ly docker
echo '{"insecure-registries":["${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}"]}' >/etc/docker/daemon.json
systemctl restart docker

docker pull "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/ceph-config-helper:${OS_TAG}" || (docker build --force-rm \
  -t "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/ceph-config-helper:${OS_TAG}" \
  --build-arg KUBE_VERSION=v${K8S_VERSION} \
  --build-arg CEPH_KEY=https://download.ceph.com/keys/release.asc \
  --build-arg CEPH_REPO=https://download.ceph.com/debian-${CEPH_VERSION}/ \
  --build-arg CEPH_RELEASE=${CEPH_VERSION} \
  --build-arg CEPH_RELEASE_TAG="${CEPH_VERSION}-1bionic" \
  -f "${OSH_IMG_LXD_LOCATION}/ceph-config-helper/Dockerfile.ubuntu_bionic" \
  "${OSH_IMG_LXD_LOCATION}/ceph-config-helper" \
&& docker push "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/ceph-config-helper:${OS_TAG}")

docker pull "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/libvirt:${OS_TAG}" || (docker build --force-rm \
  -t "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/libvirt:${OS_TAG}" \
  --build-arg FROM=docker.io/ubuntu:focal \
  --build-arg UBUNTU_RELEASE=focal \
  --build-arg CEPH_KEY=https://download.ceph.com/keys/release.asc \
  --build-arg CEPH_REPO=https://download.ceph.com/debian-${CEPH_VERSION}/ \
  --build-arg CEPH_RELEASE=${CEPH_VERSION} \
  --build-arg CEPH_RELEASE_TAG="${CEPH_VERSION}-1focal" \
  -f "${OSH_IMG_LXD_LOCATION}/libvirt/Dockerfile.ubuntu_bionic" \
  "${OSH_IMG_LXD_LOCATION}/libvirt" \
&& docker push "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/libvirt:${OS_TAG}")

docker build --force-rm \
  -t "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/loci-base:${OS_TAG}" \
  --build-arg CEPH_URL="http://download.ceph.com/debian-${CEPH_VERSION}/" \
  "${LOCI_LXD_LOCATION}/dockerfiles/${BASE_IMAGE}"

#docker build --force-rm \
#  -t "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/requirements:${OS_TAG}" \
#  --build-arg FROM="${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/loci-base:${OS_TAG}" \
#  --build-arg PROJECT=requirements \
#  --build-arg PYTHON3=yes \
#  --build-arg PROJECT_REF="stable/${OS_VERSION}" \
#  --build-arg PROJECT_RELEASE="${OS_VERSION}" \
#  --build-arg PROFILES="requirements infra python3 apache nginx haproxy lvm ceph linuxbridge openvswitch tftp ipxe qemu libvirt" \
#  --build-arg PIP_PACKAGES='psycopg2-binary uwsgi ${STABLE_VERSION_REQUIREMENTS[${OS_VERSION}]}' \
#  "${LOCI_LXD_LOCATION}"

    #--build-arg PIP_PACKAGES='psycopg2-binary psycopg2cffi psycogreen pg8000<=1.16.5 uwsgi'
for i in keystone glance cinder neutron nova placement horizon heat barbican octavia designate manila ironic magnum senlin trove; do
  docker pull "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/\${i}:${OS_TAG}" || (docker build --force-rm \
    -t "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/\${i}:${OS_TAG}" \
    --build-arg FROM="${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/loci-base:${OS_TAG}" \
    --build-arg PROJECT="\${i}" \
    --build-arg PYTHON3=yes \
    --build-arg PROJECT_REF="stable/${OS_VERSION}" \
    --build-arg PROJECT_RELEASE="${OS_VERSION}" \
    --build-arg PROFILES="\${i} requirements infra python3 apache nginx haproxy lvm ceph linuxbridge openvswitch tftp ipxe qemu libvirt" \
    --build-arg PIP_PACKAGES='psycopg2-binary uwsgi ${STABLE_VERSION_REQUIREMENTS[${OS_VERSION}]}' \
    "${LOCI_LXD_LOCATION}" \
  && docker push "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}/\${i}:${OS_TAG}")
done
wait \$(jobs -rp)
systemctl stop docker
zypper rm -uy docker
EOF
}

up(){
  "${MYDIR}/../kubedee/kubedee" up "${CLUSTER_NAME}" \
    --apiserver-extra-hostnames "kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local" \
    --enable-insecure-registry --vm \
    --num-worker "${NUM_WORKERS}" \
    --kubernetes-version "v${K8S_VERSION}" \
    --controller-limits-memory "${CONTROLLER_MEMORY_SIZE}" \
    --worker-limits-memory "${WORKER_MEMORY_SIZE}" \
    --storage-pool "${LXD_STORAGE_POOL}" \
    --rootfs-size "24GiB"

  # registry proxy setup
  local TMP_CA="$(mktemp)" TMP_SYSTEMD_SVC="$(mktemp)" \
    CACERT_PATH="/var/lib/ca-certificates/ca-bundle.pem"
    #CACERT_PATH="/etc/ssl/certs/ca-certificates.crt"
  lxc file pull "kubedee-${CLUSTER_NAME}-controller${CACERT_PATH}" "${TMP_CA}"
  chmod u+w "${TMP_CA}"
  mkdir -p "${REGISTRY_PROXY_HOST_PATH}"

  registry_proxy "${TMP_CA}"

  until kubectl -n kube-system wait --for condition=ready pod -l app=flannel,tier=node; do sleep 1; done 2>/dev/null ||:
  until kubectl -n kube-system wait --for condition=ready pod -l k8s-app=kube-dns; do sleep 1; done 2>/dev/null ||:

  export LOCAL_REGISTRY_HOST="kubedee-${CLUSTER_NAME}-registry" LOCAL_REGISTRY_PORT="5000"
  populate_local_registry

  local REGISTRY_PROXY_ADDRESS="$(docker container inspect "${REGISTRY_PROXY_HOSTNAME}" -f '{{.NetworkSettings.IPAddress}}')"
  cat <<EOF >"${TMP_SYSTEMD_SVC}"
[Service]
Environment="HTTP_PROXY=http://${REGISTRY_PROXY_ADDRESS}:3128/"
Environment="HTTPS_PROXY=http://${REGISTRY_PROXY_ADDRESS}:3128/"
Environment="NO_PROXY=${LOCAL_REGISTRY_HOST}"
EOF

  lxc file push "${TMP_CA}" "kubedee-${CLUSTER_NAME}-controller${CACERT_PATH}"
  lxc file push "${TMP_SYSTEMD_SVC}" "kubedee-${CLUSTER_NAME}-controller/etc/systemd/system/crio.service.d/registry-proxy.conf" -p
  lxc exec "kubedee-${CLUSTER_NAME}-controller" -- /bin/sh -c 'systemctl daemon-reload; systemctl restart crio'

  # volume setup
  local i j
  for i in $(lxc list -cn --format csv | grep -E "^kubedee-${CLUSTER_NAME}-worker-"); do
    lxc exec "${i}" -- zypper in -ly lvm2
    lxc file push "${TMP_CA}" "${i}${CACERT_PATH}"
    lxc file push "${TMP_SYSTEMD_SVC}" "${i}/etc/systemd/system/crio.service.d/registry-proxy.conf" -p
    lxc stop "${i}" ||:
    for j in {b..g}; do
      lxc storage volume create "${LXD_STORAGE_POOL}" "${i}-sd${j}" size="${VOLUME_SIZE}" --type block
      until lxc storage volume attach "${LXD_STORAGE_POOL}" "${i}-sd${j}" "${i}" ''; do :; done
    done
    lxc start "${i}"
  done

  rm "${TMP_CA}" "${TMP_SYSTEMD_SVC}"

  #export CEPH_MON_COUNT="${NUM_WORKERS}"
  #if [ "${CEPH_MON_COUNT}" -gt 3 ]; then CEPH_MON_COUNT=3; fi

  $("${MYDIR}/../kubedee/kubedee" kubectl-env "${CLUSTER_NAME}")
  setup_helm

  #ROOK_NETWORK="$(lxc network get "$(cat ~/.local/share/kubedee/clusters/rookery/network_id)" ipv4.address)" \
  LOCAL_REGISTRY_ADDRESS="${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}" \
  helmfile -f "${MYDIR}/helmfile.yaml" sync

  "${MYDIR}/../kubedee/kubedee" kubectl-env "${CLUSTER_NAME}"
}

down(){
  "${MYDIR}/../kubedee/kubedee" delete "${CLUSTER_NAME}" ||:
  docker rm -fv "${REGISTRY_PROXY_HOSTNAME}" ||:
  for i in $(lxc storage volume list "${LXD_STORAGE_POOL}" --format csv | awk -F, "/(^|,)kubedee-${CLUSTER_NAME}-worker-/ {print \$2}"); do
    lxc storage volume delete "${LXD_STORAGE_POOL}" "${i}"
  done
}

main(){
  : ${LXD_STORAGE_POOL:=default}
  : ${CLUSTER_NAME:=rookery}
  : ${NUM_WORKERS:=1}
  : ${K8S_VERSION:=1.20.4}
  : ${OS_VERSION:=victoria}
  : ${BASE_IMAGE:=ubuntu_bionic}
  : ${CONTROLLER_MEMORY_SIZE:=2GiB}
  : ${WORKER_MEMORY_SIZE:=12GiB}
  : ${CEPH_VERSION:=15.2.9}
  #NUM_VOLUMES="${NUM_VOLUMES:-2}"

  local SCRIPT_OP
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      up | down)
        SCRIPT_OP="${1}"
        shift
        ;;
      -N | --name)
        CLUSTER_NAME="${2}"
        shift 2
        ;;
      -n | --num)
        case "${2}" in
          ''|*[!0-9]*)
            echo "Malformed number of workers."
            exit 1
            ;;
          *) ;;
        esac
        NUM_WORKERS="${2}"
        shift 2
        ;;
      -V | --version)
        K8S_VERSION="${2}"
        shift 2
        ;;
      -s | --storage-pool)
        LXD_STORAGE_POOL="${2}"
        shift 2
        ;;
      -o | --openstack-version)
        OS_VERSION="${2}"
        shift 2
        ;;
      -b | --base-image)
        BASE_IMAGE="${2}"
        shift 2
        ;;
      -c | --controller-mem)
        CONTROLLER_MEMORY_SIZE="${2}"
        shift 2
        ;;
      -w | --worker-mem)
        WORKER_MEMORY_SIZE="${2}"
        shift 2
        ;;
      -C | --ceph-version)
        CEPH_VERSION="${2}"
        shift 2
        ;;
      *) usage;;
    esac
  done
  [ -z "${SCRIPT_OP}" ] && usage

  export OS_TAG="${OS_VERSION}-${BASE_IMAGE}" VOLUME_SIZE="${VOLUME_SIZE:-15GiB}"
  : ${REGISTRY_PROXY_HOSTNAME:="kubedee-${CLUSTER_NAME}-registry-proxy-cache.local"}
  : ${REGISTRY_PROXY_HOST_PATH:=/var/tmp/oci-registry}

  "${SCRIPT_OP}"
}
main "${@}"
