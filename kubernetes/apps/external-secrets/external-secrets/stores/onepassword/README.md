# Onepassword Connect Store

To generate a new secret for the onepassword store, run the following command:

```shell
kubectl create secret generic onepassword-connect-secret \
  --from-literal=1password-credentials.json=$(op read "op://cluster-bootstrap/jc3ggycdyf2r3yy3xmdyzf4mdm/1password-credentials.json"|base64| tr -d \\n) \
  --from-literal=token=$(op read "op://home-ops/tq2ektv45ooqrfoapybnibgmim/credential") \
  --namespace=external-secrets \
  -o yaml
```

To update the secret, run the following command:

```shell
sops --decrypt kubernetes/apps/external-secrets/external-secrets/app/secret.sops.yaml
```

```shell
task sops:encrypt
```
