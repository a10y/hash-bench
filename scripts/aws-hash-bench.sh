#!/usr/bin/env bash
# Run the local project on temporary EC2 instances through SSM. Bash 3.2+.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI_PROFILE=default
REGION=""
SUBNET=""
INSTANCE_PROFILE_NAME=""
CREATE_PROFILE=1
PLAN=0
MARKET=spot
TYPES="c8i.xlarge c8a.xlarge c8g.xlarge"
TOOLCHAIN=""
REPEATS=3
RESULTS=""

usage() {
    cat <<'EOF'
Usage: scripts/aws-hash-bench.sh [options]

Uses the selected AWS profile and its configured region (default: default).
For SSO profiles, log in first, for example:
  aws sso login --profile default

  --profile NAME              AWS CLI profile (default: default)
  --plan                       Check AWS resources; create nothing
  --instance-profile NAME      Use an existing EC2 SSM profile
  --create-instance-profile    Create a temporary SSM role/profile (default; needs IAM)
  --region REGION             Override the selected profile's region
  --subnet-id ID               Use this public subnet instead of default VPC subnets
  --types "TYPE TYPE ..."      Default: c8i.xlarge c8a.xlarge c8g.xlarge
  --on-demand                 Use On-Demand instead of one-time Spot instances
  --rust-toolchain VERSION     Exact Rust release (default: local rustc version)
  --repeats N                  Repetitions per build (default: 3)
  --results DIR                Output directory (default: results/<run-id>)
  -h, --help                  Show this help

Instances run one at a time. They need outbound internet access, but no inbound
ports, SSH keys, S3 bucket, or Session Manager plugin. Each run installs Rust,
runs generic/native builds with constant 0xA5 input, saves results, and terminates
the instance. x86 also gets a native build with BLAKE3 AVX-512 disabled.
EOF
}
die() { echo "Error: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
while (($#)); do
    case "$1" in
        --plan) PLAN=1; shift ;;
        --create-instance-profile) CREATE_PROFILE=1; shift ;;
        --on-demand) MARKET=on-demand; shift ;;
        -h|--help) usage; exit 0 ;;
        --profile|--region|--subnet-id|--types|--instance-profile|--rust-toolchain|--repeats|--results)
            (($# >= 2)) || die "$1 needs a value"
            case "$1" in
                --profile) CLI_PROFILE=$2 ;;
                --region) REGION=$2 ;; --subnet-id) SUBNET=$2 ;;
                --types) TYPES=$2 ;; --instance-profile) INSTANCE_PROFILE_NAME=$2; CREATE_PROFILE=0 ;;
                --rust-toolchain) TOOLCHAIN=$2 ;; --repeats) REPEATS=$2 ;;
                --results) RESULTS=$2 ;;
            esac
            shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ -n $CLI_PROFILE ]] || die "--profile must not be empty"
for tool in aws python3; do command -v "$tool" >/dev/null || die "Install $tool first"; done
[[ $REPEATS =~ ^[1-9][0-9]?$ ]] || die "--repeats must be 1 through 99"
[[ -n $TOOLCHAIN ]] || TOOLCHAIN=$(rustc --version | awk '{print $2}')
[[ $TOOLCHAIN =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Use an exact stable Rust release, such as 1.95.0"
read -r -a INSTANCE_TYPES <<< "$TYPES"
((${#INSTANCE_TYPES[@]} > 0)) || die "--types must not be empty"
for instance_type in "${INSTANCE_TYPES[@]}"; do
    [[ $instance_type =~ ^[a-z0-9]+\.[a-z0-9]+$ ]] || die "Invalid instance type: $instance_type"
done
# Explicit --profile avoids using another active profile in the calling shell.
export AWS_PAGER="" AWS_CLI_AUTO_PROMPT=off AWS_EC2_METADATA_DISABLED=true
if [[ -z $REGION ]]; then
    REGION=$(aws --profile "$CLI_PROFILE" configure get region) || die "Set a region in profile $CLI_PROFILE or use --region"
fi
[[ -n $REGION ]] || die "Set a region in profile $CLI_PROFILE or use --region"
aw() { aws --profile "$CLI_PROFILE" --region "$REGION" --output json --cli-connect-timeout 10 --cli-read-timeout 30 "$@"; }
RUN_ID="hash-bench-$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
[[ -n $RESULTS ]] || RESULTS="$ROOT/results/$RUN_ID"
mkdir -p "$RESULTS"
RESULTS=$(cd "$RESULTS" && pwd)
python3 - "$RESULTS" <<'PY'
import pathlib, sys
if any(pathlib.Path(sys.argv[1]).iterdir()):
    sys.exit('Use a new or empty results directory')
PY
WORK=$(mktemp -d)
SG=""
ROLE_CREATED=0
PROFILE_CREATED=0
POLICY_ATTACHED=0
ROLE_ADDED=0
MUTATIONS=0

cleanup() {
    local status=$? ids="" safe=1
    trap - EXIT INT TERM
    set +e
    if ((MUTATIONS)); then
        # Tag lookup also finds a launch whose response was lost or interrupted.
        if ! ids=$(aw ec2 describe-instances --filters "Name=tag:HashBenchRun,Values=$RUN_ID" \
            'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down' \
            --query 'Reservations[].Instances[].InstanceId' --output text); then
            safe=0
        elif [[ -n $ids && $ids != None ]]; then
            log "Terminate remaining instances: $ids"
            # EC2 IDs from AWS contain no spaces within an ID.
            # shellcheck disable=SC2086
            aw ec2 terminate-instances --instance-ids $ids >/dev/null && \
                aw ec2 wait instance-terminated --instance-ids $ids || safe=0
        fi
        if ((safe)); then
            [[ -z $SG ]] || aw ec2 delete-security-group --group-id "$SG" >/dev/null || safe=0
            if ((ROLE_ADDED)); then
                aw iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$INSTANCE_PROFILE_NAME" || safe=0
            fi
            if ((PROFILE_CREATED)); then aw iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" || safe=0; fi
            if ((POLICY_ATTACHED)); then aw iam detach-role-policy --role-name "$INSTANCE_PROFILE_NAME" --policy-arn "$SSM_POLICY" || safe=0; fi
            if ((ROLE_CREATED)); then aw iam delete-role --role-name "$INSTANCE_PROFILE_NAME" || safe=0; fi
        fi
        if ((!safe)); then
            log "Cleanup was incomplete. See $RESULTS/resources.txt; find instances with tag HashBenchRun=$RUN_ID."
            status=1
        fi
    fi
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

aw sts get-caller-identity > "$RESULTS/caller.json" || die "Run: aws sso login --profile \"$CLI_PROFILE\""
PARTITION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Arn"].split(":")[1])' "$RESULTS/caller.json")
SSM_POLICY="arn:$PARTITION:iam::aws:policy/AmazonSSMManagedInstanceCore"
if ((CREATE_PROFILE)); then
    INSTANCE_PROFILE_NAME=$RUN_ID
else
    aw iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" > "$RESULTS/instance-profile.json" || \
        die "Supply an EC2 profile with AmazonSSMManagedInstanceCore. Your caller also needs iam:GetInstanceProfile and iam:PassRole. Use --create-instance-profile only with IAM creation rights."
fi

if [[ -n $SUBNET ]]; then
    aw ec2 describe-subnets --subnet-ids "$SUBNET" > "$WORK/subnets.json"
else
    aw ec2 describe-subnets --filters Name=default-for-az,Values=true > "$WORK/subnets.json"
fi
VPC=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["Subnets"]; print(s[0]["VpcId"] if s else "")' "$WORK/subnets.json")
[[ -n $VPC ]] || die "No default subnets found. Use --subnet-id with a public subnet"
aw ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" > "$WORK/routes.json"
aw ec2 describe-instance-types --instance-types "${INSTANCE_TYPES[@]}" > "$RESULTS/instance-types.json"
aw ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$(IFS=,; echo "${INSTANCE_TYPES[*]}")" > "$WORK/offerings.json"
# Choose a public subnet that offers each CPU type. Do not silently change CPUs.
python3 - "$WORK" "$RESULTS" "${INSTANCE_TYPES[@]}" <<'PY'
import json, pathlib, sys
work, results = map(pathlib.Path, sys.argv[1:3])
load = lambda p: json.loads(p.read_text())
subnets = load(work / 'subnets.json')['Subnets']
routes = load(work / 'routes.json')['RouteTables']
offers = load(work / 'offerings.json')['InstanceTypeOfferings']
types = {x['InstanceType']: x for x in load(results / 'instance-types.json')['InstanceTypes']}
with (work / 'plan.tsv').open('w') as out:
    for name in sys.argv[3:]:
        info = types[name]
        arch = info['ProcessorInfo']['SupportedArchitectures'][0]
        if arch not in ('x86_64', 'arm64'):
            sys.exit(f'Unsupported architecture: {arch}')
        zones = {x['Location'] for x in offers if x['InstanceType'] == name}
        found = False
        for subnet in subnets:
            if subnet['AvailabilityZone'] not in zones or not subnet['AvailableIpAddressCount']:
                continue
            tables = [t for t in routes if any(a.get('SubnetId') == subnet['SubnetId'] for a in t['Associations'])]
            if not tables:
                tables = [t for t in routes if any(a.get('Main') for a in t['Associations'])]
            if any(r.get('DestinationCidrBlock') == '0.0.0.0/0' and r.get('GatewayId', '').startswith('igw-')
                   and r.get('State') == 'active' for t in tables for r in t['Routes']):
                print(name, arch, subnet['SubnetId'], subnet['AvailabilityZone'], sep='\t', file=out)
                found = True
        if not found:
            sys.exit(f'No public subnet offers {name}. Select another region, subnet, or instance type.')
PY
while IFS=$'\t' read -r instance_type arch subnet zone; do
    ami=$(aw ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$arch" \
        --query Parameter.Value --output text)
    printf '%s\t%s\t%s\t%s\t%s\n' "$instance_type" "$arch" "$subnet" "$zone" "$ami" >> "$RESULTS/plan.tsv"
done < "$WORK/plan.tsv"
printf 'Run: %s\nProfile: %s\nRegion: %s\nMarket: %s\nRust: %s\nInstance profile: %s\n' \
    "$RUN_ID" "$CLI_PROFILE" "$REGION" "$MARKET" "$TOOLCHAIN" "$INSTANCE_PROFILE_NAME" > "$RESULTS/resources.txt"
cat "$RESULTS/resources.txt" >&2
cat "$RESULTS/plan.tsv" >&2
if ((PLAN)); then log "Plan complete. No AWS resources created."; exit 0; fi

# Only copy project source and the remote runner, including uncommitted edits.
python3 - "$ROOT" "$WORK" <<'PY'
import base64, hashlib, pathlib, sys, tarfile
root, work = map(pathlib.Path, sys.argv[1:])
with tarfile.open(work / 'source.tar.gz', 'w:gz') as tar:
    for name in ('Cargo.toml', 'Cargo.lock', 'src', 'benches', 'scripts/aws-hash-bench-remote.sh'):
        path = root / name
        paths = [path] + (sorted(path.rglob('*')) if path.is_dir() else [])
        for item in paths:
            if item.is_symlink():
                sys.exit(f'Refuse source symlink: {item}')
            tar.add(item, arcname=str(item.relative_to(root)), recursive=False)
data = (work / 'source.tar.gz').read_bytes()
(work / 'source.sha256').write_text(hashlib.sha256(data).hexdigest())
encoded = base64.b64encode(data).decode()
for i in range(0, len(encoded), 12000):
    (work / f'upload-{i // 12000:04}.txt').write_text(encoded[i:i+12000])
PY

MUTATIONS=1
if ((CREATE_PROFILE)); then
    aw iam create-role --role-name "$INSTANCE_PROFILE_NAME" --assume-role-policy-document \
        '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null || \
        die "Cannot create the temporary role. Use --instance-profile with an existing SSM profile and iam:PassRole permission"
    ROLE_CREATED=1
    printf 'Created role: %s\n' "$INSTANCE_PROFILE_NAME" >> "$RESULTS/resources.txt"
    aw iam attach-role-policy --role-name "$INSTANCE_PROFILE_NAME" --policy-arn "$SSM_POLICY"
    POLICY_ATTACHED=1
    aw iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
    PROFILE_CREATED=1
    aw iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$INSTANCE_PROFILE_NAME"
    ROLE_ADDED=1
fi
SG=$(aw ec2 create-security-group --group-name "$RUN_ID" --description 'Temporary hash benchmarks; no inbound access' \
    --vpc-id "$VPC" --tag-specifications "ResourceType=security-group,Tags=[{Key=HashBenchRun,Value=$RUN_ID}]" --query GroupId --output text)
printf 'Created security group: %s\n' "$SG" >> "$RESULTS/resources.txt"

# Run a command and save its complete API response. Transfer chunks stay below
# the SSM stdout limit (24,000 characters). Never treat missing status as success.
ssm_run() {
    local script=$1 output=$2 timeout=${3:-120} command_id status deadline
    python3 - "$script" "$timeout" > "$WORK/parameters.json" <<'PY'
import json, sys
print(json.dumps({'commands': [sys.argv[1]], 'executionTimeout': [sys.argv[2]]}))
PY
    command_id=$(aw ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
        --parameters "file://$WORK/parameters.json" --timeout-seconds 120 --comment "$RUN_ID" \
        --query Command.CommandId --output text) || return 1
    printf '%s\t%s\n' "$INSTANCE" "$command_id" >> "$RESULTS/commands.tsv"
    deadline=$((SECONDS + timeout + 180))
    while ((SECONDS < deadline)); do
        if aw ssm get-command-invocation --instance-id "$INSTANCE" --command-id "$command_id" \
            > "$output.tmp" 2> "$WORK/ssm-error"; then
            mv "$output.tmp" "$output"
            status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Status"])' "$output")
            case "$status" in
                Success) return 0 ;;
                Pending|InProgress|Delayed) ;;
                *) log "SSM command $command_id ended with $status. See $output"; return 1 ;;
            esac
        elif ! grep -q InvocationDoesNotExist "$WORK/ssm-error"; then
            cat "$WORK/ssm-error" >&2
            return 1
        fi
        sleep 3
    done
    log "SSM command timed out: $command_id"
    aw ssm cancel-command --command-id "$command_id" --instance-ids "$INSTANCE" >/dev/null || true
    return 1
}

COMPLETED_TYPES=""
while IFS=$'\t' read -r instance_type arch subnet zone ami; do
    case " $COMPLETED_TYPES " in *" $instance_type "*) continue ;; esac
    case_dir="$RESULTS/$instance_type"
    mkdir -p "$case_dir"
    log "Start $instance_type ($arch, $zone, $MARKET)"
    python3 - "$ami" "$instance_type" "$subnet" "$SG" "$INSTANCE_PROFILE_NAME" "$RUN_ID" "$MARKET" "$zone" > "$WORK/launch.json" <<'PY'
import base64, json, sys
ami, kind, subnet, sg, profile, run, market, zone = sys.argv[1:]
# Shutdown terminates EC2, including if the local controller loses its connection.
user_data = '#!/bin/bash\nsystemctl enable --now amazon-ssm-agent\nsystemd-run --unit=hash-bench-expire --on-active=120m /usr/sbin/shutdown -h now\n'
tags = [{'Key': 'HashBenchRun', 'Value': run}, {'Key': 'Name', 'Value': f'{run}-{kind}'}]
request = dict(ImageId=ami, InstanceType=kind, MinCount=1, MaxCount=1,
    ClientToken=f'{run}-{kind}-{zone}', IamInstanceProfile={'Name': profile},
    NetworkInterfaces=[dict(DeviceIndex=0, SubnetId=subnet, Groups=[sg], AssociatePublicIpAddress=True,
                            DeleteOnTermination=True)],
    MetadataOptions=dict(HttpTokens='required', HttpEndpoint='enabled', HttpPutResponseHopLimit=1),
    BlockDeviceMappings=[dict(DeviceName='/dev/xvda', Ebs=dict(VolumeSize=20, VolumeType='gp3',
                                                            Encrypted=True, DeleteOnTermination=True))],
    InstanceInitiatedShutdownBehavior='terminate', UserData=base64.b64encode(user_data.encode()).decode(),
    TagSpecifications=[dict(ResourceType=t, Tags=tags) for t in ('instance', 'volume')])
if market == 'spot':
    request['InstanceMarketOptions'] = dict(MarketType='spot', SpotOptions=dict(
        SpotInstanceType='one-time', InstanceInterruptionBehavior='terminate'))
print(json.dumps(request))
PY
    # A new IAM profile can take time to reach EC2. Retry only that error.
    launched=0
    for ((attempt=1; attempt<=12; attempt++)); do
        if aw ec2 run-instances --cli-input-json "file://$WORK/launch.json" > "$case_dir/launch.json" 2> "$WORK/launch-error"; then
            launched=1; break
        fi
        if ! grep -qi 'Invalid IAM Instance Profile\|InvalidParameterValue.*[Ii]nstance[Pp]rofile' "$WORK/launch-error"; then break; fi
        sleep 10
    done
    if ((!launched)); then
        cat "$WORK/launch-error" >&2
        cp "$WORK/launch-error" "$case_dir/launch-error-$zone.txt"
        if grep -q 'InsufficientInstanceCapacity\|UnfulfillableCapacity' "$WORK/launch-error"; then
            log "No capacity in $zone. Try the next suitable subnet for $instance_type."
            continue
        fi
        die "Launch failed. See $case_dir/launch-error-$zone.txt"
    fi
    INSTANCE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Instances"][0]["InstanceId"])' "$case_dir/launch.json")
    printf 'Instance: %s %s\n' "$INSTANCE" "$instance_type" >> "$RESULTS/resources.txt"
    aw ec2 wait instance-running --instance-ids "$INSTANCE"
    log "Wait for SSM on $INSTANCE"
    deadline=$((SECONDS + 600))
    online=""
    while ((SECONDS < deadline)); do
        online=$(aw ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE" \
            --query 'InstanceInformationList[0].PingStatus' --output text)
        [[ $online != Online ]] || break
        sleep 5
    done
    [[ $online == Online ]] || die "SSM did not connect. Check the instance role, subnet routes, and outbound HTTPS"
    REMOTE="/var/tmp/$RUN_ID"
    ssm_run "mkdir -p '$REMOTE'; chmod 700 '$REMOTE'" "$case_dir/prepare.json"
    for chunk in "$WORK"/upload-*.txt; do
        name=$(basename "$chunk")
        ssm_run "printf '%s' '$(cat "$chunk")' > '$REMOTE/$name'" "$case_dir/$name.json"
    done
    ssm_run "set -e; cd '$REMOTE'; cat upload-*.txt | base64 -d > source.tar.gz; echo '$(cat "$WORK/source.sha256")  source.tar.gz' | sha256sum -c -; tar -xzf source.tar.gz" "$case_dir/unpack.json"
    log "Run benchmarks on $INSTANCE; full setup output goes to setup.log"
    run_ok=1
    ssm_run "cd '$REMOTE' && bash scripts/aws-hash-bench-remote.sh '$TOOLCHAIN' '$REPEATS' > setup.log 2>&1" \
        "$case_dir/run.json" 5400 || run_ok=0
    # Make a bundle even after a failed setup, if the instance is still available.
    if ssm_run "set -e; cd '$REMOTE'; mkdir -p results; cp setup.log results/; tar -czf results.tar.gz results; wc -c < results.tar.gz; sha256sum results.tar.gz" "$case_dir/bundle.json"; then
        read -r size digest < <(python3 -c 'import json,sys; x=json.load(open(sys.argv[1]))["StandardOutputContent"].split(); print(x[0],x[1])' "$case_dir/bundle.json")
        [[ $size =~ ^[0-9]+$ && $digest =~ ^[0-9a-f]{64}$ ]] || die "Invalid result bundle metadata"
        : > "$case_dir/results.tar.gz"
        for ((offset=0; offset<size; offset+=12000)); do
            ssm_run "dd if='$REMOTE/results.tar.gz' bs=12000 skip=$((offset / 12000)) count=1 status=none | base64 -w0" "$case_dir/download.json"
            python3 - "$case_dir/download.json" >> "$case_dir/results.tar.gz" <<'PY'
import base64, json, sys
sys.stdout.buffer.write(base64.b64decode(json.load(open(sys.argv[1]))['StandardOutputContent'], validate=True))
PY
        done
        python3 - "$case_dir/results.tar.gz" "$digest" <<'PY'
import hashlib, pathlib, sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit('Result checksum mismatch')
PY
        log "Saved $case_dir/results.tar.gz"
    else
        run_ok=0
        log "Could not retrieve results. A Spot interruption can cause this."
    fi
    aw ec2 terminate-instances --instance-ids "$INSTANCE" > "$case_dir/terminate.json"
    aw ec2 wait instance-terminated --instance-ids "$INSTANCE"
    ((run_ok)) || die "Remote run failed; inspect $case_dir"
    COMPLETED_TYPES="$COMPLETED_TYPES $instance_type"
done < "$RESULTS/plan.tsv"
for instance_type in "${INSTANCE_TYPES[@]}"; do
    case " $COMPLETED_TYPES " in
        *" $instance_type "*) ;;
        *) die "No capacity for $instance_type in the selected subnets. Try --on-demand, another region, or --subnet-id" ;;
    esac
done
log "All runs complete. Results: $RESULTS"
