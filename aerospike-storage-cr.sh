#!/bin/bash
cat << EOF | kubectl apply -f-
apiVersion: portal.gloo.solo.io/v1beta1
kind: Storage
metadata:
  name: aerospike-storage
  namespace: gloo-system
spec:
  apikeyStorage:
    aerospike:
      hostname: 192.168.31.179
      namespace: solo
      #port: 3000
      nodeTlsName: nodetls1
      port: 4333
      certPath: "/custom-certs/tls.crt"
      keyPath: "/custom-certs/tls.key"
      rootCaPath: "/custom-certs/ca.crt"
EOF

kubectl rollout restart deployment -n gloo-portal gloo-portal-controller
kubectl rollout restart deployment -n gloo-system extauth
kubectl get -n default authconfig default-petstore-product-dev -oyaml
