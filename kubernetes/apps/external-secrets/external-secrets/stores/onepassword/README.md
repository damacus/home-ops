# Onepassword Connect Store

To generate a new secret for the onepassword store, run the following command:

```shell
kubectl create secret generic onepassword-connect-secret \
  --from-literal=1password-credentials.json=$(op read "op://Personal/1password-credentials/1password-credentials.json"|base64| tr -d \\n) \
  --from-literal=token=$(op read "op://home-ops/tq2ektv45ooqrfoapybnibgmim/credential") \
  --dry-run=client \
  -o yaml
```

Change string, to stringData, then encrypt the secret with sops
