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
      hostname: 192.168.31.151
      port: 3000
      namespace: aerogloo
EOF

kubectl rollout restart deployment -n gloo-portal gloo-portal-controller
kubectl rollout restart deployment -n gloo-system extauth
kubectl get -n default authconfig default-petstore-product-dev -oyaml
