#!/bin/bash

set -eu

LAMBDA_SIZE="${1:-128}"

dir=$(mktemp -p . -d lambda_XXXXX)

for src in "crowbar" "python" "go" "rust-aws-lambda"; do
  mkdir -p "$dir/$src"
  cp "$src/deploy.zip" "$dir/$src/deploy-warm.zip"
  cp "$src/deploy.zip" "$dir/$src/deploy-cold.zip"

  # modify each deploy zip to cache-bust just in case lambda gets really good
  # at caching zips within an account across functions
  pushd "$dir/$src"
  echo "$RANDOM" > warm
  echo "$RANDOM" > cold
  zip deploy-warm.zip warm
  zip deploy-cold.zip cold
  rm -f warm cold
  popd
done

# cool, now $dir is setup for terraform's expectations. Create the functions.
rand="$RANDOM"
terraform apply -auto-approve -state="$dir/tfstate" -var "prefix=$rand" -var "zipdir=$dir" ./01_terraform-create

# Now the boring part. I think lambda might initialize functions as warm, so we wait a good hour for the functions to cool down.

start_time="$(date -Is)"
echo "Sleeping 1 hour. Get some covfefe"
sleep "1h"


# Now we can warm up the warm function, flip on xray for them, trigger each
# function once, and record our data

for fn in "crowbar_hello_world" "python_hello_world" "rust-aws-lambda_hello_world" "go_hello_world"; do
  # warm em twice, why not
  aws lambda invoke --function-name "${rand}${fn}_warm" /dev/null
  aws lambda invoke --function-name "${rand}${fn}_warm" /dev/null
done

# now that they're warm, turn on xray and invoke everything
terraform apply -auto-approve -state="$dir/tfstate" -var "prefix=$rand" -var "zipdir=$dir" ./02_terraform-enable-xray

for fn in "crowbar_hello_world" "python_hello_world" "rust-aws-lambda_hello_world" "go_hello_world"; do
  aws lambda invoke --function-name "${rand}${fn}_warm" /dev/null
  aws lambda invoke --function-name "${rand}${fn}_cold" /dev/null
done

# Collect data

out="output/$rand"
mkdir -p "$out"

echo "$LAMBDA_SIZE" > "$out/memory"

for fn in "crowbar_hello_world" "python_hello_world" "rust-aws-lambda_hello_world" "go_hello_world"; do
  got=false
  while [[ "$got" == "false" ]]; do
    warm="$(aws xray get-trace-summaries --start-time="$start_time" --end-time="$(date -Is)" --filter-expression "service(\"${rand}${fn}_warm\")" | jq '.TraceSummaries[].Duration' -r -c)"
    cold="$(aws xray get-trace-summaries --start-time="$start_time" --end-time="$(date -Is)" --filter-expression "service(\"${rand}${fn}_cold\")" | jq '.TraceSummaries[].Duration' -r -c)"
    if [[ "$warm" != "" ]] && [[ "$cold" != "" ]]; then
      got=true
    else
      sleep 10
    fi
  done
  echo "$warm" > "$out/${fn}_warm"
  echo "$cold" > "$out/${fn}_cold"
done

# finally, cleanup
terraform destroy -auto-approve -state="$dir/tfstate" -var "prefix=$rand" -var "zipdir=$dir" ./02_terraform-enable-xray
rm -rf "$dir"