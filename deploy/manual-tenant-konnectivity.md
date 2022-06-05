# Manual setup of a Tenant Cluster with Konnectivity
In Kamaji, a Tenant Cluster has the Control Plane running in the Admin Cluster. The Tenant Control Plane is created by a dedicated controller. This guide reports manual steps required to create a Tenant Cluster with support for [Konnectivity](https://kubernetes.io/docs/tasks/extend-kubernetes/setup-konnectivity/).

* [Variable Definitions](#variable-definitions)
* [Create configuration](#create-configuration)
* [Configure tenant on `etcd`](#configure-tenant-on-etcd)
* [Generate certificates](#generate-certificates)
* [Generate kubeconfig files](#generate-kubeconfig-files)
* [Generate secrets](generate-secrets)
* [Create tenant control plane](#create-tenant-control-plane)
* [Configure tenant control plane](#configure-tenant-control-plane)
* [Install Konnectivity Agent](#install-konnectivity-agent)
* [Install CNI](#install-cni)
* [Prepare nodes-to-join](#prepare-nodes-to-join)
* [Join nodes](#join-nodes)
* [Cleanup](#cleanup-tenant-cluster)


### Variable Definitions

Throughout the instructions, shell variables are used to indicate values that you should adjust to your own environment:

```bash
source kamaji-external-etcd.env
source kamaji-manual-tenant.env
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
  advertiseAddress: ${TENANT_PUBLIC_ADDR}
  bindPort: ${TENANT_PUBLIC_PORT}
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
controlPlaneEndpoint: "${TENANT_PUBLIC_ADDR}:${TENANT_PUBLIC_PORT}"
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
  - ${TENANT_NAME}.${TENANT_PUBLIC_DOMAIN}
  - ${TENANT_PUBLIC_ADDR}
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
  --apiserver-cert-extra-sans localhost,${TENANT_ADDR},${TENANT_PUBLIC_ADDR},${TENANT_NAME},${TENANT_NAME}.${TENANT_DOMAIN},${TENANT_NAME}.${TENANT_PUBLIC_DOMAIN}

kubeadm init phase certs apiserver-kubelet-client --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki

kubeadm init phase certs front-proxy-ca --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki

kubeadm init phase certs front-proxy-client --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki

kubeadm init phase certs sa --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki
```

Copy the `etcd` certificates so that the tenant cluster apiserver can use the multi-tenant `etcd` cluster

```bash
cp kamaji/etcd/ca.crt kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/etcd-ca.crt
cp kamaji/etcd/ca.key kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/etcd-ca.key
```

### Generate kubeconfig files

#### Scheduler

```bash
kubeadm init phase kubeconfig scheduler \
  --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki \
  --kubeconfig-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}

kubectl config set-cluster kubernetes \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/scheduler.conf \
  --server=https://localhost:${TENANT_PORT}
```

#### Controller Manager

```bash
kubeadm init phase kubeconfig controller-manager \
  --cert-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki \
  --kubeconfig-dir $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}

kubectl config set-cluster kubernetes \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/controller-manager.conf \
  --server=https://localhost:${TENANT_PORT}
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

#### Konnectivity Server

Generate certificates for the Konnectivity Server

```bash
cat > konnectivity-csr.json <<EOF  
{
  "CN": "system:konnectivity-server",
  "key": {
    "algo": "rsa",
    "size": 2048
  }
}
EOF

cfssl gencert \
  -ca=$PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/ca.crt \
  -ca-key=$PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/ca.key \
  -config=cfssl-cert-config.json \
  -profile=client-authentication \
  konnectivity-csr.json | cfssljson -bare konnectivity

```

Copy the certificates on the expected directory:

```bash
mv konnectivity.pem kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/konnectivity.crt
mv konnectivity-key.pem kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/konnectivity.key
rm konnectivity*
```

Create the `kubeconfig` file for the Konnectivity Server

```bash

kubectl config set-credentials system:konnectivity-server \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/konnectivity-server.conf \ 
  --client-certificate $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/konnectivity.crt \
  --client-key $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/konnectivity.key \
  --embed-certs=true


kubectl config set-cluster kubernetes \
  --server https://localhost:6443 \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/konnectivity-server.conf \
  --certificate-authority $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/pki/ca.crt \
  --embed-certs=true

kubectl config set-context system:konnectivity-server@kubernetes \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/konnectivity-server.conf \
  --cluster kubernetes \
  --user system:konnectivity-server

kubectl config use-context system:konnectivity-server@kubernetes \
  --kubeconfig $PWD/kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/konnectivity-server.conf 

```


#### Check files tree

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
    └── manual-00
        ├── admin.conf
        ├── controller-manager.conf
        ├── konnectivity-server.conf
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
        │   ├── etcd-ca.key
        │   ├── front-proxy-ca.crt
        │   ├── front-proxy-ca.key
        │   ├── front-proxy-client.crt
        │   ├── front-proxy-client.key
        │   ├── konnectivity.crt
        │   ├── konnectivity.key
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

#### Konnectivity Server

```bash
kubectl -n ${TENANT_NAMESPACE} create secret generic konnectivity-server-kubeconfig --from-file kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/konnectivity-server.conf
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
        - --advertise-address=${TENANT_PUBLIC_ADDR}
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
        - --kubelet-preferred-address-types=ExternalIP,InternalIP,Hostname
        - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
        - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
        - --requestheader-allowed-names=front-proxy-client
        - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
        - --requestheader-extra-headers-prefix=X-Remote-Extra-
        - --requestheader-group-headers=X-Remote-Group
        - --requestheader-username-headers=X-Remote-User
        - --secure-port=${TENANT_PUBLIC_PORT}
        - --service-account-issuer=https://localhost:${TENANT_PUBLIC_PORT}
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
        - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
        - --egress-selector-config-file=/opt/konnectivity/egress-selector-configuration.yaml
        livenessProbe:
          httpGet:
            path: /livez
            port: ${TENANT_PUBLIC_PORT}
            scheme: HTTPS
        readinessProbe:
          httpGet:
            path: /readyz
            port: ${TENANT_PUBLIC_PORT}
            scheme: HTTPS
        startupProbe:
          httpGet:
            path: /livez
            port: ${TENANT_PUBLIC_PORT}
            scheme: HTTPS
        resources:
          requests:
            cpu: 250m
        volumeMounts:
        - mountPath: /etc/kubernetes/konnectivity-server
          name: konnectivity-uds
          readOnly: false
        - mountPath: /opt/konnectivity
          name: egress-selector-configuration
          readOnly: true
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
      - name: konnectivity-server
        image: us.gcr.io/k8s-artifacts-prod/kas-network-proxy/proxy-server:v0.0.16
        command: ["/proxy-server"]
        args: [
          "-v=8",
          "--logtostderr=true",
          "--uds-name=/etc/kubernetes/konnectivity-server/konnectivity-server.socket",
          "--cluster-cert=/etc/kubernetes/pki/apiserver.crt",
          "--cluster-key=/etc/kubernetes/pki/apiserver.key",
          "--mode=grpc",
          "--server-port=0",
          "--agent-port=8132",
          "--admin-port=8133",
          "--health-port=8134",
          "--agent-namespace=kube-system",
          "--agent-service-account=konnectivity-agent",
          "--kubeconfig=/etc/kubernetes/konnectivity-server.conf",
          "--authentication-audience=system:konnectivity-server"
        ]        
        livenessProbe:
          httpGet:
            scheme: HTTP
            port: 8134
            path: /healthz
          initialDelaySeconds: 30
          timeoutSeconds: 60
        resources:
          requests:
            cpu: 100m
        ports:
        - name: agentport
          containerPort: 8132
        - name: adminport
          containerPort: 8133
        - name: healthport
          containerPort: 8134
        volumeMounts:
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: konnectivity-server-kubeconfig
          mountPath: /etc/kubernetes/konnectivity-server.conf
          subPath: konnectivity-server.conf
          readOnly: true
        - name: konnectivity-uds
          mountPath: /etc/kubernetes/konnectivity-server
          readOnly: false
      volumes:
      - name: konnectivity-uds
        emptyDir:
          medium: Memory
      - name: egress-selector-configuration
        configMap:
          name: egress-selector-configuration
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
      - name: konnectivity-server-kubeconfig
        secret:
          secretName: konnectivity-server-kubeconfig
EOF

```

> Note we disable `etcd` compaction on tenant apiserver by setting `--etcd-compaction-interval="0"`.

Create the config map containing the Egress Configuration for the Konnectivity Server

```yaml
cat > kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/egress-selector-configuration.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: egress-selector-configuration
  namespace: ${TENANT_NAMESPACE}
data:
  egress-selector-configuration.yaml: |
    apiVersion: apiserver.k8s.io/v1beta1
    kind: EgressSelectorConfiguration
    egressSelections:
    - name: cluster
      connection:
        proxyProtocol: GRPC
        transport:
          uds:
            udsName: /etc/kubernetes/konnectivity-server/konnectivity-server.socket
EOF
```

Create the service to expose the Tenant Control Plane

```yaml
cat > kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/control-plane-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
  name: ${TENANT_NAME}
  namespace: ${TENANT_NAMESPACE}
spec:
  ports:
  - name: apiserver
    port: ${TENANT_PUBLIC_PORT}
    protocol: TCP
    targetPort: ${TENANT_PUBLIC_PORT}
  - name: proxyserver
    port: 8132
    protocol: TCP
    targetPort: 8132
  - name: admin-proxyserver
    port: 8133
    protocol: TCP
    targetPort: 8132
  - name: health-proxyserver
    port: 8134
    protocol: TCP
    targetPort: 8132
  selector:
    kamaji.clastix.io/soot: ${TENANT_NAME}
  type: LoadBalancer
  loadBalancerIP: ${TENANT_ADDR}
EOF
```


Apply the manifests

```bash
kubectl create -f kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/egress-selector-configuration.yaml
kubectl create -f kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/control-plane-deploy.yaml
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

### Install Konnectivity Agent
Create the Konnectiviy Agent manifests in order to join remote worker nodes to the Tenant Control Plane:

```yaml
cat > kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/konnectivity-agent.yaml <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
    k8s-app: konnectivity-agent
  namespace: kube-system
  name: konnectivity-agent
spec:
  selector:
    matchLabels:
      k8s-app: konnectivity-agent
  template:
    metadata:
      labels:
        k8s-app: konnectivity-agent
    spec:
      priorityClassName: system-cluster-critical
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
      containers:
        - image: us.gcr.io/k8s-artifacts-prod/kas-network-proxy/proxy-agent:v0.0.16
          name: konnectivity-agent
          command: ["/proxy-agent"]
          args: [
            "-v=8",
            "--logtostderr=true",
            "--ca-cert=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
            "--proxy-server-host=${TENANT_PUBLIC_ADDR}",
            "--proxy-server-port=8132",
            "--admin-server-port=8133",
            "--health-server-port=8134",
            "--service-account-token-path=/var/run/secrets/tokens/konnectivity-agent-token"
          ]
          volumeMounts:
            - mountPath: /var/run/secrets/tokens
              name: konnectivity-agent-token
          livenessProbe:
            httpGet:
              port: 8134
              path: /healthz
            initialDelaySeconds: 15
            timeoutSeconds: 15
      serviceAccountName: konnectivity-agent
      volumes:
        - name: konnectivity-agent-token
          projected:
            sources:
              - serviceAccountToken:
                  path: konnectivity-agent-token
                  audience: system:konnectivity-server
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:konnectivity-server
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: system:konnectivity-server
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: konnectivity-agent
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
EOF
```

On the Tenant Control Plane, apply the manifests:

```bash
kubectl --kubeconfig=kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf apply -f kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/konnectivity-agent.yaml
```

### Install CNI
Install the CNI plugin of choice, for example, Calico:

```bash
kubectl --kubeconfig kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf apply -f calico-cni/calico-crd.yaml
kubectl --kubeconfig kamaji/${TENANT_NAMESPACE}/${TENANT_NAME}/admin.conf apply -f calico-cni/calico.yaml
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

```bash
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

## Cleanup
Remove the worker nodes joined the tenant cluster. For each worker node, login and clean it

```bash
HOSTS=(${WORKER0} ${WORKER1} ${WORKER2} ${WORKER3})
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