# Manual setup of a Tenant Cluster
In Kamaji, a Tenant Cluster has the Control Plane running in the Admin Cluster. The Tenant Control Plane is created by a dedicated controller. This guide reports manual steps required to create a Tenant Cluster instead of the controller.

* [Variable Definitions](#variable-definitions)
* [Create configuration](#create-configuration)
* [Configure tenant on `etcd`](#configure-tenant-on-etcd)
* [Generate certificates](#generate-certificates)
* [Generate kubeconfig files](#generate-kubeconfig-files)
* [Generate secrets](generate-secrets)
* [Create tenant control plane](#create-tenant-control-plane)
* [Configure tenant control plane](#configure-tenant-control-plane)
* [Prepare nodes-to-join](#prepare-nodes-to-join)
* [Join nodes](#join-nodes)
* [Cleanup](#cleanup-tenant-cluster)


### Variable Definitions

Throughout the instructions, shell variables are used to indicate values that you should adjust to your own environment:

```bash
# etcd machine addresses
export ETCD0=192.168.32.10
export ETCD1=192.168.32.11
export ETCD2=192.168.32.12

# tenant cluster parameters
export TENANT_NAMESPACE=tenants
export TENANT_NAME=tenant-00
export TENANT_DOMAIN=clastix.labs
export TENANT_VERSION=v1.23.1
export TENANT_ADDR=192.168.32.150 # IP used to expose the tenant control plane
export TENANT_PORT=6443 # PORT used to expose the tenant control plane
export TENANT_POD_CIDR=10.36.0.0/16
export TENANT_SVC_CIDR=10.96.0.0/16
export TENANT_DNS_SERVICE=10.96.0.10

# tenant node addresses
export WORKER0=192.168.32.90
export WORKER1=192.168.32.91
export WORKER2=192.168.32.92
export WORKER3=192.168.32.93
```

### Create configuration
Create a `kubeadm` configuration file with proper values:

```bash
mkdir -p kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}
cat > kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/kubeadm-config.yaml <<EOF  
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token:
  ttl: 48h0m0s
  usages:
  - signing
  - authentication
localAPIEndpoint:
  advertiseAddress: ${TENANT_ADDR}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: ${TENANT_NAME}
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
kubernetesVersion: ${TENANT_VERSION}
clusterName: ${TENANT_NAME}
certificatesDir: /etc/kubernetes/pki
imageRepository: k8s.gcr.io
networking:
  dnsDomain: cluster.local
  podSubnet: ${TENANT_POD_CIDR}
  serviceSubnet: ${TENANT_SVC_CIDR}
dns:
  type: CoreDNS
controlPlaneEndpoint: "${TENANT_ADDR}:6443"
etcd:
  external:
    endpoints:
    - https://${ETCD0}:2379
    - https://${ETCD1}:2379
    - https://${ETCD2}:2379
    caFile: /etc/kubernetes/pki/etcd/ca.crt
    certFile: /etc/kubernetes/pki/apiserver-etcd-client.crt
    keyFile: /etc/kubernetes/pki/apiserver-etcd-client.key
apiServer:
  certSANs:
  - localhost
  - ${TENANT_NAME}
  - ${TENANT_NAME}.${TENANT_DOMAIN}
  - ${TENANT_ADDR}
  extraArgs:
    etcd-prefix: /${TENANT_NAME}
    etcd-compaction-interval: "0"
EOF
```

### Configure tenant on `etcd` 
Generate certificates for the tenant user of `etcd` to be used by the Kubernetes tenant cluster 

```bash
cat > ${TENANT_NAME}-csr.json <<EOF  
{
  "CN": "${TENANT_NAME}",
  "key": {
    "algo": "rsa",
    "size": 2048
  }
}
EOF
```

```bash
cfssl gencert \
  -ca=kamaji/etcd/ca.crt \
  -ca-key=kamaji/etcd/ca.key \
  -config=cfssl-cert-config.json \
  -profile=client-authentication \
  ${TENANT_NAME}-csr.json | cfssljson -bare ${TENANT_NAME}
```

Copy the certificates on the expected directory so we can setup the Kubernetes tenant cluster in multi-tenant `etcd`:

```bash
mkdir -p kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
mv ${TENANT_NAME}.pem kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/apiserver-etcd-client.crt
mv ${TENANT_NAME}-key.pem kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/apiserver-etcd-client.key
rm ${TENANT_NAME}*
```

Make sure to access the multi-tenant `etcd`:

```bash
export ETCDCTL_CACERT=kamaji/etcd/ca.crt
export ETCDCTL_CERT=kamaji/etcd/root.crt
export ETCDCTL_KEY=kamaji/etcd/root.key
export ETCDCTL_ENDPOINTS=https://${ETCD0}:2379
```

Create the tenant namespace

```bash
etcdctl user add --no-password=true ${TENANT_NAME}
etcdctl role add ${TENANT_NAME}
etcdctl user grant-role ${TENANT_NAME} ${TENANT_NAME}
etcdctl role grant-permission ${TENANT_NAME} --prefix=true readwrite /${TENANT_NAME}/
```

### Generate certificates
Use the `kubeadm` init phase to generate certificates for the tenant cluster:

```bash
kubeadm init phase certs ca --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
kubeadm init phase certs apiserver \
  --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki \
  --apiserver-cert-extra-sans localhost,${TENANT_ADDR},${TENANT_NAME},${TENANT_NAME}.${TENANT_DOMAIN}
kubeadm init phase certs apiserver-kubelet-client --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
kubeadm init phase certs front-proxy-ca --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
kubeadm init phase certs front-proxy-client --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
kubeadm init phase certs sa --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
```

Copy the `etcd` certificates so that the tenant cluster apiserver can use the multi-tenant `etcd` cluster

```bash
cp kamaji/etcd/ca.crt kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/etcd-ca.crt
```

### Generate kubeconfig files
Use the `kubeadm` init phase to generate kubeconfig files for the tenant cluster:

#### Scheduler

```bash
kubeadm init phase kubeconfig scheduler \
  --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki \
  --kubeconfig-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}

kubectl config set-cluster kubernetes \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/scheduler.conf \
  --server=https://localhost:6443
```

#### Controller Manager

```bash
kubeadm init phase kubeconfig controller-manager \
  --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki \
  --kubeconfig-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}

kubectl config set-cluster kubernetes \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/controller-manager.conf \
  --server=https://localhost:6443
```

#### Cluster Admin

```bash
kubeadm init phase kubeconfig admin \
  --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki \
  --kubeconfig-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}

kubectl config set-cluster kubernetes \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf \
  --server=https://${TENANT_ADDR}:${TENANT_PORT}
```

You should end up with the following tree:

```
tree kamaji
kamaji
├── etcd
│   ├── ca.crt
│   ├── ca.key
│   ├── root.crt
│   └── root.key
└── tenants
    └── tenant-02
        ├── admin.conf
        ├── control-plane-deploy.yaml
        ├── control-plane-service.yaml
        ├── controller-manager.conf
        ├── kubeadm-config.yaml
        ├── pki
        │   ├── apiserver-etcd-client.crt
        │   ├── apiserver-etcd-client.key
        │   ├── apiserver-kubelet-client.crt
        │   ├── apiserver-kubelet-client.key
        │   ├── apiserver.crt
        │   ├── apiserver.key
        │   ├── ca.crt
        │   ├── ca.key
        │   ├── etcd-ca.crt
        │   ├── front-proxy-ca.crt
        │   ├── front-proxy-ca.key
        │   ├── front-proxy-client.crt
        │   ├── front-proxy-client.key
        │   ├── sa.key
        │   └── sa.pub
        └── scheduler.conf
```

### Generate secrets
On the admin cluster, create a namespace for the tenant cluster

```bash
kubectl create namespace ${TENANT_NAMESPACE}
```

Certificates and `kubeconfig` files for components of the tenant control plane are injected in the control plane pods as secrets:

#### APIs Server

```bash
kubectl -n ${TENANT_NAMESPACE} create secret generic k8s-certs --from-file=kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
```

#### Scheduler

```bash
kubectl -n ${TENANT_NAMESPACE} create secret generic scheduler-kubeconfig --from-file kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/scheduler.conf
```

#### Controller Manager

```bash
kubectl -n ${TENANT_NAMESPACE} create secret generic controller-manager-kubeconfig --from-file kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/controller-manager.conf
```

### Create tenant control plane
Create a Deployment manifest for the control plane of the tenant cluster

```yaml
cat > kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/control-plane-deploy.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TENANT_NAME}
  namespace: ${TENANT_NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      kamaji.clastix.io/soot: ${TENANT_NAME}
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
    type: RollingUpdate
  template:
    metadata:
      labels:
        kamaji.clastix.io/soot: ${TENANT_NAME}
    spec:
      priorityClassName: system-node-critical
      containers:
      - name: kube-apiserver
        image: k8s.gcr.io/kube-apiserver:${TENANT_VERSION}
        imagePullPolicy: IfNotPresent
        command:
        - kube-apiserver
        - --advertise-address=${TENANT_ADDR}
        - --allow-privileged=true
        - --authorization-mode=Node,RBAC
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --enable-admission-plugins=NodeRestriction,PodNodeSelector,LimitRanger,ResourceQuota,MutatingAdmissionWebhook,ValidatingAdmissionWebhook
        - --enable-bootstrap-token-auth=true
        - --etcd-cafile=/etc/kubernetes/pki/etcd-ca.crt
        - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
        - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
        - --etcd-servers=https://${ETCD0}:2379,https://${ETCD1}:2379,https://${ETCD2}:2379
        - --etcd-prefix=/${TENANT_NAME}
        - --etcd-compaction-interval=0
        - --insecure-port=0
        - --service-cluster-ip-range=${TENANT_SVC_CIDR}
        - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
        - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
        - --kubelet-preferred-address-types=Hostname,InternalIP,ExternalIP
        - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
        - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
        - --requestheader-allowed-names=front-proxy-client
        - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
        - --requestheader-extra-headers-prefix=X-Remote-Extra-
        - --requestheader-group-headers=X-Remote-Group
        - --requestheader-username-headers=X-Remote-User
        - --secure-port=6443
        - --service-account-issuer=https://localhost:6443
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
        - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
        livenessProbe:
          httpGet:
            path: /livez
            port: 6443
            scheme: HTTPS
        readinessProbe:
          httpGet:
            path: /readyz
            port: 6443
            scheme: HTTPS
        startupProbe:
          httpGet:
            path: /livez
            port: 6443
            scheme: HTTPS
        resources:
          requests:
            cpu: 250m
        volumeMounts:
        - mountPath: /etc/ssl/certs
          name: ca-certs
          readOnly: true
        - mountPath: /etc/ca-certificates
          name: etc-ca-certificates
          readOnly: true
        - mountPath: /usr/local/share/ca-certificates
          name: usr-local-share-ca-certificates
          readOnly: true
        - mountPath: /usr/share/ca-certificates
          name: usr-share-ca-certificates
          readOnly: true
        - mountPath: /etc/kubernetes/pki
          name: k8s-certs
          readOnly: true
      - name: kube-scheduler
        image: k8s.gcr.io/kube-scheduler:${TENANT_VERSION}
        imagePullPolicy: IfNotPresent
        command:
        - kube-scheduler
        - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
        - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
        - --bind-address=0.0.0.0
        - --kubeconfig=/etc/kubernetes/scheduler.conf
        - --leader-elect=true
        - --port=0  
        livenessProbe:
          httpGet:
            path: /healthz
            port: 10259
            scheme: HTTPS
        name: kube-scheduler
        startupProbe:
          httpGet:
            path: /healthz
            port: 10259
            scheme: HTTPS
        resources:
          requests:
            cpu: 100m
        volumeMounts:
        - mountPath: /etc/kubernetes/scheduler.conf
          name: scheduler-kubeconfig
          subPath: scheduler.conf
          readOnly: true
      - name: kube-controller-manager
        image: k8s.gcr.io/kube-controller-manager:${TENANT_VERSION}
        imagePullPolicy: IfNotPresent 
        command:
        - kube-controller-manager
        - --allocate-node-cidrs=true
        - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
        - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
        - --bind-address=0.0.0.0
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --cluster-name=${TENANT_NAME}
        - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
        - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
        - --controllers=*,bootstrapsigner,tokencleaner
        - --kubeconfig=/etc/kubernetes/controller-manager.conf
        - --leader-elect=true
        - --port=0
        - --service-cluster-ip-range=${TENANT_SVC_CIDR}
        - --cluster-cidr=${TENANT_POD_CIDR}
        - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
        - --root-ca-file=/etc/kubernetes/pki/ca.crt
        - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
        - --use-service-account-credentials=true
        livenessProbe:
          httpGet:
            path: /healthz
            port: 10257
            scheme: HTTPS
        startupProbe:
          httpGet:
            path: /healthz
            port: 10257
            scheme: HTTPS
        resources:
          requests:
            cpu: 200m
        volumeMounts:
        - mountPath: /etc/ssl/certs
          name: ca-certs
          readOnly: true
        - mountPath: /etc/ca-certificates
          name: etc-ca-certificates
          readOnly: true
        - mountPath: /usr/local/share/ca-certificates
          name: usr-local-share-ca-certificates
          readOnly: true
        - mountPath: /usr/share/ca-certificates
          name: usr-share-ca-certificates
          readOnly: true
        - mountPath: /etc/kubernetes/controller-manager.conf
          name: controller-manager-kubeconfig
          subPath: controller-manager.conf
          readOnly: true
        - mountPath: /etc/kubernetes/pki
          name: k8s-certs
          readOnly: true
      volumes:
      - hostPath:
          path: /etc/ssl/certs
          type: DirectoryOrCreate
        name: ca-certs
      - hostPath:
          path: /etc/ca-certificates
          type: DirectoryOrCreate
        name: etc-ca-certificates
      - hostPath:
          path: /usr/local/share/ca-certificates
          type: DirectoryOrCreate
        name: usr-local-share-ca-certificates
      - hostPath:
          path: /usr/share/ca-certificates
          type: DirectoryOrCreate
        name: usr-share-ca-certificates
      - name: k8s-certs
        secret:
          secretName: k8s-certs
      - name: scheduler-kubeconfig
        secret:
          secretName: scheduler-kubeconfig
      - name: controller-manager-kubeconfig
        secret:
          secretName: controller-manager-kubeconfig
EOF
```

> Note we disable `etcd` compaction on tenant apiserver by setting `--etcd-compaction-interval="0"`.

Apply the manifest

```bash
kubectl create -f kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/control-plane-deploy.yaml
```

The control plane of the tenant cluster is exposed through one of the service type:

- `ClusterIP`
- `NodePort`
- `LoadBalancer`

Optionally, it can be exposed through an Ingress with its FQDN `${TENANT_NAME}.${TENANT_DOMAIN}`. In this example, we're going to expose through a `LoadBalancer` service type, assuming it is available in the Kamaji setup.


```yaml
cat > kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/control-plane-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
  name: control-plane
  namespace: ${TENANT_NAMESPACE}
spec:
  ports:
  - port: ${TENANT_PORT}
    protocol: TCP
    targetPort: 6443
  selector:
    kamaji.clastix.io/soot: ${TENANT_NAME}
  type: LoadBalancer
  loadBalancerIP: ${TENANT_ADDR}
EOF
```

Apply the manifest

```bash
kubectl create -f kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/control-plane-service.yaml
```

A tenant cluster control plane is now running as deployment and it is exposed through a service.

Check if control plane of the tenant is reachable and in healty state

```bash
curl -k https://${TENANT_ADDR}:${TENANT_PORT}/healthz
curl -k https://${TENANT_ADDR}:${TENANT_PORT}/version
```

Authenticate to tenant cluster using the cluster admin `kubeconfig` file

```bash
kubectl --kubeconfig=kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf get namespaces

NAME              STATUS   AGE
default           Active   5m
kube-node-lease   Active   5m
kube-public       Active   5m
kube-system       Active   5m
```

```bash
kubectl --kubeconfig=kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf cluster-info
```

### Configure tenant control plane
Use the `kubeadm` init phase to complete the setup of tenant control plane

```bash
kubeadm init phase upload-config kubeadm \
  --config $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/kubeadm-config.yaml \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf
```

> Currently, there is an issue with the next step below. The `kubeadm` init phase tries to set CRI Socket information to the control-plane nodes as an annotation. However, in Kamaji, there are not nodes for the tenant control plane and the step below will hang trying to get such nodes: interrupt the `kubeadm` process with Ctrl-C and move to the next step. 

```bash
kubeadm init phase upload-config kubelet \
  --config $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/kubeadm-config.yaml \
  --kubeconfig=$PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf --v=8
```

```bash
kubeadm init phase addon coredns \
  --config $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/kubeadm-config.yaml \
  --kubeconfig=$PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf
```

```bash
kubeadm init phase addon kube-proxy \
  --config $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/kubeadm-config.yaml \
  --kubeconfig=$PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf
```

```bash
kubeadm init phase bootstrap-token \
  --config $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/kubeadm-config.yaml \
  --kubeconfig=$PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf
```

### Prepare nodes to join
Use bash script `nodes-prerequisites.sh` to install all the dependencies on all the worker nodes:

- Install `containerd` as container runtime
- Install `crictl`, the command line for working with `containerd`
- Install `kubectl`, `kubelet`, and `kubeadm` in the desired version

Run the installation script:

```bash
HOSTS=(${WORKER0} ${WORKER1} ${WORKER2} ${WORKER3})
./nodes-prerequisites.sh ${TENANT_VERSION:1} ${HOSTS[@]}
```

### Join nodes
Request a token from the tenant control plane in order to join the worker nodes. This generates a join command

```bash
JOIN_CMD=$(echo "sudo ")$(kubeadm --kubeconfig=kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf token create --print-join-command)
```

Join the worker nodes

```
HOSTS=(${WORKER0} ${WORKER1} ${WORKER2} ${WORKER3})
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} -t ${JOIN_CMD};
done
```

After tenant worker nodes joined the tenant control plane, check

```bash
kubectl --kubeconfig kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf get nodes
```

Worker nodes remain in `NotReady` state since no CNI component is installed on the tenant cluster.

Install the CNI plugin of choice, we unse Calico in this example

```bash
kubectl --kubeconfig kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf apply -f calico-cni/calico-crd.yaml
kubectl --kubeconfig kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf apply -f calico-cni/calico.yaml
```

Once installed, worker nodes move to `Ready` state

```bash
kubectl --kubeconfig kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf get nodes 
```

## Cleanup
Remove the worker nodes joined the tenant cluster. For each worker node, login and clean it

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} -t 'sudo kubeadm reset -f';
  ssh ${USER}@${HOST} -t 'sudo rm -rf /etc/cni/net.d';
  ssh ${USER}@${HOST} -t 'sudo systemctl reboot';
done
```

Delete the tenant cluster control plane by deleting the related namespace

```bash
kubectl delete namespace ${NAMESPACE} 
```

Also make sure to remove the tenant on the `etcd` cluster

```bash
etcdctl del --prefix /${TENANT_NAME}/
etcdctl user del ${TENANT_NAME}
etcdctl role del ${TENANT_NAME}
```

Finally, cleanup certificates and configuration files of the tenant cluster

```bash
rm -rf kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}
```