webhook_secret_exists=$(oc get secret webhook-secret-verify-source-code-pipeline-demo -n securesign-pipelines-demo --ignore-not-found)
if [[ -n $webhook_secret_exists ]]; then
  echo "Already found an existing \"webhook-secret-verify-source-code-pipeline-demo\" Secret in the \"securesign-pipelines-demo\" namespace."
  read -s -p "Enter what you would like to update this secret to (leave blank to not change it): " webhook_secret
  echo ""
  if [[ -n $webhook_secret ]]; then
    oc create secret generic webhook-secret-verify-source-code-pipeline-demo -n securesign-pipelines-demo \
      --from-literal=webhook-secret-key=$webhook_secret  --dry-run=client -o yaml | oc replace -f -
  else
    echo "Skipping webhook secret update." 
  fi
else
  read -s -p "Enter the secret value used to setup the Github webhook: " webhook_secret
  oc create secret generic webhook-secret-verify-source-code-pipeline-demo --from-literal=webhook-secret-key=$webhook_secret -n securesign-pipelines-demo
  echo ""
fi

read -p "Enter the case sensitive github organization and repo combination (ex: 'securesign/pipelines-demo'): " github_org_and_repo

check_repo_full_name=$(
  curl -L -s \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$github_org_and_repo \
  | jq .full_name | cut -d "\"" -f 2
)

if [[ $check_repo_full_name != $github_org_and_repo ]]; then
  echo "Couldnt find this repo. Some common issues that would prevent this from working:
    1. Repo is not on github.
    2. Repo is not private.
    3. Repo is not listed with proper casing.
      - To check casing you can run this command:
        \`curl -L -s \\
            -H "Accept: application/vnd.github+json" \\
            -H "X-GitHub-Api-Version: 2022-11-28" \\
            https://api.github.com/repos/$github_org_and_repo \\
          | jq .full_name \`"
  exit 1
else
  echo "repo exists, continuing."
fi

trigger_value="(header.match('X-GitHub-Event', 'push') && body.repository.full_name == '$github_org_and_repo')" \
yq -i '.spec.triggers.0.interceptors.1.params.0.value = env(trigger_value)' ./verify-source-el.yaml 

tuf_route_name=$(oc get routes -n tuf-system | grep 'tuf' | awk '{print $1}')
tuf_route_hostname=$(oc get route -n tuf-system $tuf_route_name -o jsonpath='{.spec.host}')
generic_route_hostname="${tuf_route_hostname:4:${#tuf_route_hostname}}"
host="el-verify-source.$generic_route_hostname"

yq -i '.spec.host = "'$host'"' ./verify-source-el-route.yaml

echo "------------------ Keycloak User Configuration -----------------"
read -p "Enter the username for the keycloak user (must be all lowercase letters): " keycloak_user
keycloak_user=$(echo "$keycloak_user" | awk '{print tolower($0)}')
read -s -p "Now enter the password for the keycloak user: " keycloak_pass
echo ""
read -p "Please enter an email for the keycloak user: " keycloak_email
read -p "Enter your first name: " first_name
read -p "Enter your last name: " last_name

yq -i '.metadata.name = "'$keycloak_user'"' ./keycloak-user.yaml
yq -i '.spec.user.username = "'$keycloak_user'"' ./keycloak-user.yaml
yq -i '.spec.user.email = "'$keycloak_email'"' ./keycloak-user.yaml
yq -i '.spec.user.credentials.0.value = "'$keycloak_pass'"' ./keycloak-user.yaml
yq -i '.spec.user.firstName = "'$first_name'"' ./keycloak-user.yaml
yq -i '.spec.user.lastName = "'$last_name'"' ./keycloak-user.yaml

yq -i '.spec.params.0.value = "'$keycloak_email'"' ./verify-source-code-triggerbinding.yaml

pipeline_sa_secrets=$(oc get sa pipeline -n securesign-pipelines-demo -o yaml | yq .secrets)
pipeline_sa_secret_name=$(echo $pipeline_sa_secrets | grep "pipeline-dockercfg-" | yq .0.name)
# cat verify-source-code-pipeline.yaml | yq '.spec.tasks.1.params = .spec.tasks.1.params + {"name":"test", "value":"testvalue"}