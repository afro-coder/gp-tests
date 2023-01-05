#!/bin/bash
PORTAL_VERSION=1.2.10
# Assumes Keycloak is exposed via ingress or port forwarding
KEYCLOAK_URL=http://keycloak.default.svc.cluster.local:32222
# Assumes Gloo Edge is already installed
GLOO_GW_IP=$(glooctl proxy address | cut -d':' -f1)

# Install Portal and wait for control plane to reach ready state
echo "Installing Gloo Portal version ${PORTAL_VERSION}"
helm install gloo-portal gloo-portal/gloo-portal -n gloo-portal --values gloo-values.yaml --version 1.2.10 --create-namespace
kubectl -n gloo-portal wait pod --all --for condition=Ready --timeout -1s

# Install Keycloak
echo "Installing Keycloak"
kubectl create -f keycloak.yaml
kubectl rollout status deploy/keycloak

# Get Keycloak URL and token
KEYCLOAK_TOKEN=$(curl -s -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)

# Create client, users, and groups in Keycloak
echo "Configuring Keycloak"
read -r client token <<<$(curl -s -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"expiration": 0, "count": 1}' $KEYCLOAK_URL/admin/realms/master/clients-initial-access | jq -r '[.id, .token] | @tsv')
read -r id secret <<<$(curl -X POST -d "{ \"clientId\": \"${client}\" }" -H "Content-Type:application/json" -H "Authorization: bearer ${token}" ${KEYCLOAK_URL}/realms/master/clients-registrations/default| jq -r '[.id, .secret] | @tsv')
curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X PUT -H "Content-Type: application/json" -d '{"serviceAccountsEnabled": true, "authorizationServicesEnabled": true, "redirectUris": ["https://portal.mycompany.corp:31500/callback", "http://portal.mycompany.corp:31500/callback", "http://'${GLOO_GW_IP}'/callback"]}' $KEYCLOAK_URL/admin/realms/master/clients/${id}
curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"name": "group", "protocol": "openid-connect", "protocolMapper": "oidc-usermodel-attribute-mapper", "config": {"claim.name": "group", "jsonType.label": "String", "user.attribute": "group", "id.token.claim": "true", "access.token.claim": "true"}}' $KEYCLOAK_URL/admin/realms/master/clients/${id}/protocol-mappers/models
curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"name": "users"}' $KEYCLOAK_URL/admin/realms/master/groups
curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"name": "execs"}' $KEYCLOAK_URL/admin/realms/master/groups
curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"username": "user1", "email": "user1@solo.io", "enabled": true, "groups": ["users"], "attributes": {"group": "users"}, "credentials": [{"type": "password", "value": "password", "temporary": false}]}' $KEYCLOAK_URL/admin/realms/master/users
curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"username": "user2", "email": "user2@example.com", "enabled": true, "groups": ["users"], "attributes": {"group": "users"}, "credentials": [{"type": "password", "value": "password", "temporary": false}]}' $KEYCLOAK_URL/admin/realms/master/users
curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"username": "exec1", "email": "exec1@solo.io", "enabled": true, "groups": ["execs"], "attributes": {"group": "execs"}, "credentials": [{"type": "password", "value": "password", "temporary": false}]}' $KEYCLOAK_URL/admin/realms/master/users


KEYCLOAK_CLIENT=$client
KEYCLOAK_ID=$id
KEYCLOAK_SECRET=$(curl -H "Authorization: bearer ${KEYCLOAK_TOKEN}" -H "Content-Type: application/json"  $KEYCLOAK_URL/admin/realms/master/clients/$KEYCLOAK_ID/client-secret | jq -r .value)


cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: petstore-portal-oidc-secret
  namespace: default
data:
  client_secret: $(echo $KEYCLOAK_SECRET | base64)
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: default
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: default
  labels:
    app: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - image: docker.io/kennethreitz/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
        env:
        - name: GUNICORN_CMD_ARGS
          value: "--capture-output --error-logfile - --access-logfile - --access-logformat '%(h)s %(t)s %(r)s %(s)s Host: %({Host}i)s}'"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: petstore-v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: petstore
      version: v1
  template:
    metadata:
      labels:
        app: petstore
        version: v1
    spec:
      containers:
        - name: petstore
          image: swaggerapi/petstore
          # env:
          #   - name: SWAGGER_BASE_PATH
          #     value: /
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: petstore-v1
spec:
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
  selector:
    app: petstore
    version: v1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: petstore-v2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: petstore
      version: v2
  template:
    metadata:
      labels:
        app: petstore
        version: v2
    spec:
      containers:
        - name: petstore
          image: swaggerapi/petstore
          # env:
          #   - name: SWAGGER_BASE_PATH
          #     value: /
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: petstore-v2
spec:
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
  selector:
    app: petstore
    version: v2
---
apiVersion: portal.gloo.solo.io/v1beta1
kind: APIDoc
metadata:
  name: petstore-openapi-v1-pets
  namespace: default
spec:
  openApi:
    content:
      fetchUrl: https://raw.githubusercontent.com/solo-io/workshops/master/gloo-portal/openapi-specs/petstore-openapi-v1-pets.json
---
apiVersion: portal.gloo.solo.io/v1beta1
kind: APIDoc
metadata:
  name: petstore-openapi-v1-users
  namespace: default
spec:
  openApi:
    content:
      fetchUrl: https://raw.githubusercontent.com/solo-io/workshops/master/gloo-portal/openapi-specs/petstore-openapi-v1-users.json
---
apiVersion: portal.gloo.solo.io/v1beta1
kind: APIDoc
metadata:
  name: petstore-openapi-v2-full
  namespace: default
spec:
  openApi:
    content:
      fetchUrl: https://raw.githubusercontent.com/solo-io/workshops/master/gloo-portal/openapi-specs/petstore-openapi-v2-full.json
---
apiVersion: portal.gloo.solo.io/v1beta1
kind: APIProduct
metadata:
  name: petstore-product
  namespace: default
  labels:
    app: petstore
spec:
  displayInfo: 
    title: Petstore Product
    description: Fabulous API product for the Petstore
  usagePlans:
    - one
    - two
    - three
  versions:
  - name: v1 # ------------ VERSION 1 -------------
    apis:
      - apiDoc:
          name: petstore-openapi-v1-pets
          namespace: default
      - apiDoc:
          name: petstore-openapi-v1-users
          namespace: default
    gatewayConfig:
      route:
        inlineRoute:
          backends:
            - upstream:
                name: default-petstore-v1-8080
                namespace: gloo-system
  - name: v2 # ------------ VERSION 2 -------------
    apis:
    - apiDoc:
        name: petstore-openapi-v2-full
        namespace: default
    gatewayConfig:
      route:
        inlineRoute:
          backends:
            - upstream:
                name: default-petstore-v2-8080
                namespace: gloo-system
---
apiVersion: portal.gloo.solo.io/v1beta1
kind: Environment
metadata:
  name: dev
  namespace: default
spec:
  domains:
    - api.mycompany.corp:31500 # the domain name where the API will be exposed
  displayInfo:
    description: This environment is meant for developers to deploy and test their APIs.
    displayName: Development
  basePath: /ecommerce # a global basepath for our APIs
  apiProducts: # we will select our APIProduct using a selector and the 2 version of it
    - namespaces:
      - "*" 
      labels:
      - key: app
        operator: In
        values:
        - petstore
      versions:
        names:
        - v1
        - v2
      basePath: "{%version%}" # this will dynamically prefix the API path with the version name
  gatewayConfig:
    disableRoutes: false # we actually want to expose the APIs on a Gateway (optional)
  parameters:
    usagePlans:
      one:
        displayName: Plan One
        authPolicy:
          apiKey: { }
        rateLimit:
          requestsPerUnit: 3
          unit: MINUTE
      two:
        displayName: Plan Two
        authPolicy:
          apiKey: { }
        rateLimit:
          requestsPerUnit: 30
          unit: MINUTE
      three:
        displayName: Plan Three
        authPolicy:
          apiKey: { }

---
apiVersion: portal.gloo.solo.io/v1beta1
kind: Portal
metadata:
  name: ecommerce-portal
  namespace: default
spec:
  displayName: E-commerce Portal
  description: The Gloo Portal for the Petstore API and much more!
  banner:
    fetchUrl: https://i.imgur.com/EXbBN1a.jpg
  favicon:
    fetchUrl: https://i.imgur.com/QQwlQG3.png
  primaryLogo:
    fetchUrl: https://i.imgur.com/hjgPMNP.png
  customStyling: {}
  staticPages: []

  domains:
  - portal.mycompany.corp:31500 # ------ THE DOMAIN NAME ---------

  publishedEnvironments: # ---- APIs we will publish -----
  - name: dev
    namespace: default

  allApisPublicViewable: true # this will make APIs visible by unauthenticated users

  oidcAuth:
    clientId: ${KEYCLOAK_CLIENT}
    clientSecret:
      name: petstore-portal-oidc-secret
      namespace: default
      key: client_secret # this is the k8s secret we have created above
    groupClaimKey: group # we will use the 'group' claim in the 'id_token' to associate the user with a group
    issuer: ${KEYCLOAK_URL}/realms/master

  portalUrlPrefix: http://portal.mycompany.corp:31500/
---
apiVersion: portal.gloo.solo.io/v1beta1
kind: Group
metadata:
  name: users
  namespace: default
spec:
  displayName: corporate users
  accessLevel:
    apis:
    - environments:
        names:
          - dev
        namespaces:
          - '*'
      # -------------- Enforce the 'trusted' usage plan (JWT) ---------------
      usagePlans:
        - one
        - two
        - three
      # -----------------------------------------------------------------
      products: {}
    portals:
    - name: ecommerce-portal
      namespace: default
  oidcGroup:
    groupName: users # this represents the group name in the IdP (Keycloak)
EOF

