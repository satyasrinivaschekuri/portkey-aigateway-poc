#!/bin/bash

# Read configuration from portkey.env
if [ -f "portkey.env" ]; then
    source portkey.env
else
    echo "Error: portkey.env file not found"
    exit 1
fi

ENVIRONMENT=$(grep ENVIRONMENT portkey.env | cut -d '=' -f2)
DOCKER_USERNAME=$(grep DOCKER_USERNAME portkey.env | cut -d '=' -f2)
DOCKER_PASSWORD=$(grep DOCKER_PASSWORD portkey.env | cut -d '=' -f2)
#AWS_ACCESS_KEY_ID=$(grep AWS_ACCESS_KEY_ID portkey.env | cut -d '=' -f2)
#AWS_SECRET_ACCESS_KEY=$(grep AWS_SECRET_ACCESS_KEY portkey.env | cut -d '=' -f2)
AWS_REGION=$(grep AWS_REGION portkey.env | cut -d '=' -f2)
PORTKEY_CLIENT_AUTH=$(grep PORTKEY_CLIENT_AUTH portkey.env | cut -d '=' -f2)
SUBNET_IDS=$(grep SUBNET_IDS portkey.env | cut -d '=' -f2)
AWS_ACCOUNT_ID=$(grep AWS_ACCOUNT_ID portkey.env | cut -d '=' -f2)
VPC_ID=$(grep VPC_ID portkey.env | cut -d '=' -f2)

# init aws cli using credentials in portkey.env
#aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
#aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
#aws configure set region ${AWS_REGION}

CLUSTER_NAME=portkey-ai
TASK_ROLE_ARN=arn:aws:iam::196856463470:role/SandboxServiceRole
EXECUTION_ROLE_ARN=arn:aws:iam::196856463470:role/SandboxServiceRole

echo "Setting up Docker Hub credentials in Secrets Manager..."
DOCKER_CREDS_JSON=$(cat <<EOF
{
    "username": "${DOCKER_USERNAME}",
    "password": "${DOCKER_PASSWORD}"
}
EOF
)

# Try to get existing secret
EXISTING_SECRET=$(aws secretsmanager describe-secret \
    --secret-id "portkey/docker-credentials" \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing Docker credentials secret..."
    DOCKER_CREDENTIALS_SECRET_ARN=$(echo $EXISTING_SECRET | jq -r '.ARN')
else
    echo "Creating new Docker credentials secret..."
    DOCKER_CREDENTIALS_RESPONSE=$(aws secretsmanager create-secret \
        --name "portkey/docker-credentials" \
        --description "Docker Hub credentials for Portkey images" \
        --secret-string "${DOCKER_CREDS_JSON}" \
        --tags Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})
    
    DOCKER_CREDENTIALS_SECRET_ARN=$(echo $DOCKER_CREDENTIALS_RESPONSE | jq -r '.ARN')
fi


# Create or update the ECS task execution role policy
echo "Updating ECS task execution role policy..."
#TASK_EXECUTION_POLICY=$(cat <<EOF
#{
#    "Version": "2012-10-17",
#    "Statement": [
#        {
#            "Effect": "Allow",
#            "Action": [
#                "secretsmanager:GetSecretValue"
#            ],
#            "Resource": [
#                "${DOCKER_CREDENTIALS_SECRET_ARN}"
#            ]
#        },
#        {
#            "Effect": "Allow",
#            "Action": [
#                "ecr:GetAuthorizationToken",
#                "ecr:BatchCheckLayerAvailability",
#                "ecr:GetDownloadUrlForLayer",
#                "ecr:BatchGetImage",
#                "logs:CreateLogStream",
#                "logs:PutLogEvents"
#            ],
#            "Resource": "*"
#        }
#    ]
#}
#EOF
#)

# Create or update the policy
#aws iam put-role-policy \
#    --role-name ecsTaskExecutionRole \
#    --policy-name PortkeySecretsPolicy \
#    --policy-document "${TASK_EXECUTION_POLICY}"

# Create private S3 bucket with encryption
echo "Creating private S3 bucket..."
BUCKET_NAME="portkey-private-${AWS_ACCOUNT_ID}-${AWS_REGION}"

aws s3api create-bucket \
    --bucket ${BUCKET_NAME} \
    --region ${AWS_REGION}

echo "S3 bucket ${BUCKET_NAME} created successfully"

echo "Creating ECS cluster..."
aws ecs create-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy \
        capacityProvider=FARGATE,weight=1,base=1 \
    --tags key=Service,value=Portkey \
    --region ${AWS_REGION}

# Create security groups
echo "Creating security groups..."

echo "Setting up Portkey security group..."
EXISTING_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=portkey-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region ${AWS_REGION})

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
    echo "Using existing Portkey security group: ${EXISTING_SG}"
    PORTKEY_SECURITY_GROUP=$EXISTING_SG
else
    echo "Creating new Portkey security group..."
    PORTKEY_SG_RESPONSE=$(aws ec2 create-security-group \
        --group-name portkey-sg \
        --description "Security group for Portkey" \
        --vpc-id ${VPC_ID} \
        --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=portkey-sg}]' \
        --region ${AWS_REGION})

    PORTKEY_SECURITY_GROUP=$(echo $PORTKEY_SG_RESPONSE | jq -r '.GroupId')
fi

aws ec2 authorize-security-group-ingress \
    --group-id ${PORTKEY_SECURITY_GROUP} \
    --protocol tcp \
    --port 3306 \
    --cidr 0.0.0.0/0 \
    --region ${AWS_REGION}

aws ec2 authorize-security-group-ingress \
    --group-id ${PORTKEY_SECURITY_GROUP} \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0 \
    --region ${AWS_REGION}

aws ec2 authorize-security-group-ingress \
    --group-id ${PORTKEY_SECURITY_GROUP} \
    --protocol tcp \
    --port 8123 \
    --cidr 0.0.0.0/0 \
    --region ${AWS_REGION}

aws ec2 authorize-security-group-ingress \
    --group-id ${PORTKEY_SECURITY_GROUP} \
    --protocol tcp \
    --port 6379 \
    --cidr 0.0.0.0/0 \
    --region ${AWS_REGION}

# EFS Security Group
EFS_SG_NAME="portkey-efs-sg"
EFS_SECURITY_GROUP=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${EFS_SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region ${AWS_REGION})

if [ "$EFS_SECURITY_GROUP" = "None" ] || [ -z "$EFS_SECURITY_GROUP" ]; then
    echo "Creating new EFS security group..."
    EFS_SG_RESPONSE=$(aws ec2 create-security-group \
        --group-name ${EFS_SG_NAME} \
        --description "Security group for Portkey EFS" \
        --vpc-id ${VPC_ID} \
        --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=portkey-efs-sg}]' \
        --region ${AWS_REGION})
    
    EFS_SECURITY_GROUP=$(echo $EFS_SG_RESPONSE | jq -r '.GroupId')
else
    echo "Using existing EFS security group: ${EFS_SECURITY_GROUP}"
fi

# Allow gateway to access EFS
aws ec2 authorize-security-group-ingress \
    --group-id ${EFS_SECURITY_GROUP} \
    --protocol tcp \
    --port 2049 \
    --source-group ${PORTKEY_SECURITY_GROUP} \
    --region ${AWS_REGION}

# Allow all outbound traffic for all security groups
for SG in ${PORTKEY_SECURITY_GROUP} ${EFS_SECURITY_GROUP}; do
    aws ec2 authorize-security-group-egress \
        --group-id ${SG} \
        --protocol -1 \
        --port -1 \
        --cidr 0.0.0.0/0 \
        --region ${AWS_REGION}
done

# Check for existing EFS with portkey-storage tag
echo "Checking for existing EFS file system..."
EXISTING_EFS=$(aws efs describe-file-systems \
    --region ${AWS_REGION} | \
    jq -r '.FileSystems[] | select(.Tags[] | select(.Key=="Name" and .Value=="portkey-storage")) | .FileSystemId' | head -n1)

if [ -n "$EXISTING_EFS" ]; then
    echo "Using existing EFS file system: ${EXISTING_EFS}"
    EFS_ID=$EXISTING_EFS
else
    echo "Creating new EFS file system for databases..."
    EFS_RESPONSE=$(aws efs create-file-system \
        --performance-mode generalPurpose \
        --throughput-mode bursting \
        --encrypted \
        --tags Key=Name,Value=portkey-storage Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    EFS_ID=$(echo $EFS_RESPONSE | jq -r '.FileSystemId')

    echo "Waiting for EFS file system to be available..."
    while true; do
        STATUS=$(aws efs describe-file-systems \
            --file-system-id $EFS_ID \
            --region ${AWS_REGION} \
            | jq -r '.FileSystems[0].LifeCycleState')
        
        if [ "$STATUS" = "available" ]; then
            echo "EFS file system is now available"
            break
        fi
        
        echo "EFS status: $STATUS. Waiting..."
        sleep 10
    done
fi

# Create mount targets in each subnet
for SUBNET in ${SUBNET_IDS//,/ }; do
    aws efs create-mount-target \
        --file-system-id $EFS_ID \
        --subnet-id $SUBNET \
        --security-groups ${EFS_SECURITY_GROUP} \
        --region ${AWS_REGION}
done

# Check/Create MySQL Access Point
echo "Setting up MySQL access point..."
MYSQL_AP=$(aws efs describe-access-points \
    --region ${AWS_REGION} | \
    jq -r --arg fsid "$EFS_ID" '.AccessPoints[] | select(.FileSystemId==$fsid and (.Tags[] | select(.Key=="Name" and .Value=="portkey-mysql"))) | .AccessPointId' | head -n1)

if [ -z "$MYSQL_AP" ]; then
    echo "Creating new MySQL access point..."
    MYSQL_AP=$(aws efs create-access-point \
        --file-system-id $EFS_ID \
        --posix-user Uid=999,Gid=999 \
        --root-directory Path=/mysql,CreationInfo="{OwnerUid=999,OwnerGid=999,Permissions=755}" \
        --tags Key=Name,Value=portkey-mysql Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION} | jq -r '.AccessPointId')
else
    echo "Using existing MySQL access point: ${MYSQL_AP}"
fi

# Check/Create Redis Access Point
echo "Setting up Redis access point..."
REDIS_AP=$(aws efs describe-access-points \
    --region ${AWS_REGION} | \
    jq -r --arg fsid "$EFS_ID" '.AccessPoints[] | select(.FileSystemId==$fsid and (.Tags[] | select(.Key=="Name" and .Value=="portkey-redis"))) | .AccessPointId' | head -n1)

if [ -z "$REDIS_AP" ]; then
    echo "Creating new Redis access point..."
    REDIS_AP=$(aws efs create-access-point \
        --file-system-id $EFS_ID \
        --posix-user Uid=999,Gid=999 \
        --root-directory Path=/redis,CreationInfo="{OwnerUid=999,OwnerGid=999,Permissions=755}" \
        --tags Key=Name,Value=portkey-redis Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION} | jq -r '.AccessPointId')
else
    echo "Using existing Redis access point: ${REDIS_AP}"
fi

# Check/Create Clickhouse Access Point
echo "Setting up Clickhouse access point..."
CLICKHOUSE_AP=$(aws efs describe-access-points \
    --region ${AWS_REGION} | \
    jq -r --arg fsid "$EFS_ID" '.AccessPoints[] | select(.FileSystemId==$fsid and (.Tags[] | select(.Key=="Name" and .Value=="portkey-clickhouse"))) | .AccessPointId' | head -n1)

if [ -z "$CLICKHOUSE_AP" ]; then
    echo "Creating new Clickhouse access point..."
    CLICKHOUSE_AP=$(aws efs create-access-point \
        --file-system-id $EFS_ID \
        --posix-user Uid=999,Gid=999 \
        --root-directory Path=/clickhouse,CreationInfo="{OwnerUid=999,OwnerGid=999,Permissions=755}" \
        --tags Key=Name,Value=portkey-clickhouse Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION} | jq -r '.AccessPointId')
else
    echo "Using existing Clickhouse access point: ${CLICKHOUSE_AP}"
fi

# Create a properly formatted subnet list for AWS CLI JSON
SUBNET_LIST_JSON=$(echo ${SUBNET_IDS} | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')

echo "Creating ALBs..."

# Check/Create Frontend ALB
EXISTING_FRONTEND_ALB=$(aws elbv2 describe-load-balancers \
    --names portkey-frontend-alb \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing Frontend ALB..."
    FRONTEND_ALB_ARN=$(echo $EXISTING_FRONTEND_ALB | jq -r '.LoadBalancers[0].LoadBalancerArn')
    FRONTEND_ALB_DNS=$(echo $EXISTING_FRONTEND_ALB | jq -r '.LoadBalancers[0].DNSName')
else
    echo "Creating new Frontend ALB..."
    FRONTEND_ALB_RESPONSE=$(aws elbv2 create-load-balancer \
        --name portkey-frontend-alb \
        --subnets ${SUBNET_LIST_JSON} \
        --security-groups ${PORTKEY_SECURITY_GROUP} \
        --scheme internet-facing \
        --type application \
        --tags Key=Name,Value=portkey-frontend-alb Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    FRONTEND_ALB_ARN=$(echo $FRONTEND_ALB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')
    FRONTEND_ALB_DNS=$(echo $FRONTEND_ALB_RESPONSE | jq -r '.LoadBalancers[0].DNSName')
fi

# Check/Create Backend ALB
EXISTING_BACKEND_ALB=$(aws elbv2 describe-load-balancers \
    --names portkey-backend-alb \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing Backend ALB..."
    BACKEND_ALB_ARN=$(echo $EXISTING_BACKEND_ALB | jq -r '.LoadBalancers[0].LoadBalancerArn')
    BACKEND_ALB_DNS=$(echo $EXISTING_BACKEND_ALB | jq -r '.LoadBalancers[0].DNSName')
else
    echo "Creating new Backend ALB..."
    BACKEND_ALB_RESPONSE=$(aws elbv2 create-load-balancer \
        --name portkey-backend-alb \
        --subnets ${SUBNET_LIST_JSON} \
        --security-groups ${PORTKEY_SECURITY_GROUP} \
        --scheme internal \
        --type application \
        --tags Key=Name,Value=portkey-backend-alb Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    BACKEND_ALB_ARN=$(echo $BACKEND_ALB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')
    BACKEND_ALB_DNS=$(echo $BACKEND_ALB_RESPONSE | jq -r '.LoadBalancers[0].DNSName')
fi

# Check/Create Gateway ALB
EXISTING_GATEWAY_ALB=$(aws elbv2 describe-load-balancers \
    --names portkey-gateway-alb \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing Gateway ALB..."
    GATEWAY_ALB_ARN=$(echo $EXISTING_GATEWAY_ALB | jq -r '.LoadBalancers[0].LoadBalancerArn')
    GATEWAY_ALB_DNS=$(echo $EXISTING_GATEWAY_ALB | jq -r '.LoadBalancers[0].DNSName')
else
    echo "Creating new Gateway ALB..."
    GATEWAY_ALB_RESPONSE=$(aws elbv2 create-load-balancer \
        --name portkey-gateway-alb \
        --subnets ${SUBNET_LIST_JSON} \
        --security-groups ${PORTKEY_SECURITY_GROUP} \
        --scheme internet-facing \
        --type application \
        --tags Key=Name,Value=portkey-gateway-alb Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    GATEWAY_ALB_ARN=$(echo $GATEWAY_ALB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')
    GATEWAY_ALB_DNS=$(echo $GATEWAY_ALB_RESPONSE | jq -r '.LoadBalancers[0].DNSName')
fi

# Check/Create Redis NLB
EXISTING_REDIS_NLB=$(aws elbv2 describe-load-balancers \
    --names portkey-redis-nlb \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing Redis NLB..."
    REDIS_NLB_ARN=$(echo $EXISTING_REDIS_NLB | jq -r '.LoadBalancers[0].LoadBalancerArn')
    REDIS_NLB_DNS=$(echo $EXISTING_REDIS_NLB | jq -r '.LoadBalancers[0].DNSName')
else
    echo "Creating new Redis NLB..."
    REDIS_NLB_RESPONSE=$(aws elbv2 create-load-balancer \
        --name portkey-redis-nlb \
        --subnets ${SUBNET_LIST_JSON} \
        --scheme internal \
        --type network \
        --tags Key=Name,Value=portkey-redis-nlb Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    REDIS_NLB_ARN=$(echo $REDIS_NLB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')
    REDIS_NLB_DNS=$(echo $REDIS_NLB_RESPONSE | jq -r '.LoadBalancers[0].DNSName')
fi

# Create Data Service ALB
EXISTING_DATASERVICE_ALB=$(aws elbv2 describe-load-balancers \
    --names portkey-dataservice-alb \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing data service ALB..."
    DATASERVICE_ALB_ARN=$(echo $EXISTING_DATASERVICE_ALB | jq -r '.LoadBalancers[0].LoadBalancerArn')
    DATASERVICE_ALB_DNS=$(echo $EXISTING_DATASERVICE_ALB | jq -r '.LoadBalancers[0].DNSName')
else
    echo "Creating new data service ALB..."
    DATASERVICE_ALB_RESPONSE=$(aws elbv2 create-load-balancer \
        --name portkey-dataservice-alb \
        --subnets ${SUBNET_LIST_JSON} \
        --security-groups ${PORTKEY_SECURITY_GROUP} \
        --scheme internal \
        --type application \
        --tags Key=Name,Value=portkey-dataservice-alb Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    DATASERVICE_ALB_ARN=$(echo $DATASERVICE_ALB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')
    DATASERVICE_ALB_DNS=$(echo $DATASERVICE_ALB_RESPONSE | jq -r '.LoadBalancers[0].DNSName')
fi


# Create MySQL NLB
EXISTING_MYSQL_NLB=$(aws elbv2 describe-load-balancers \
    --names portkey-mysql-nlb \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing MySQL NLB..."
    MYSQL_NLB_ARN=$(echo $EXISTING_MYSQL_NLB | jq -r '.LoadBalancers[0].LoadBalancerArn')
    MYSQL_NLB_DNS=$(echo $EXISTING_MYSQL_NLB | jq -r '.LoadBalancers[0].DNSName')
else
    echo "Creating new MySQL NLB..."
    MYSQL_NLB_RESPONSE=$(aws elbv2 create-load-balancer \
        --name portkey-mysql-nlb \
        --subnets ${SUBNET_LIST_JSON} \
        --scheme internal \
        --type network \
        --tags Key=Name,Value=portkey-mysql-nlb Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    MYSQL_NLB_ARN=$(echo $MYSQL_NLB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')
    MYSQL_NLB_DNS=$(echo $MYSQL_NLB_RESPONSE | jq -r '.LoadBalancers[0].DNSName')
fi

# Create Clickhouse ALB
EXISTING_CLICKHOUSE_ALB=$(aws elbv2 describe-load-balancers \
    --names portkey-clickhouse-alb \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing Clickhouse ALB..."
    CLICKHOUSE_ALB_ARN=$(echo $EXISTING_CLICKHOUSE_ALB | jq -r '.LoadBalancers[0].LoadBalancerArn')
    CLICKHOUSE_ALB_DNS=$(echo $EXISTING_CLICKHOUSE_ALB | jq -r '.LoadBalancers[0].DNSName')
else
    echo "Creating new Clickhouse ALB..."
    CLICKHOUSE_ALB_RESPONSE=$(aws elbv2 create-load-balancer \
        --name portkey-clickhouse-alb \
        --subnets ${SUBNET_LIST_JSON} \
        --security-groups ${PORTKEY_SECURITY_GROUP} \
        --scheme internal \
        --type application \
        --tags Key=Name,Value=portkey-clickhouse-alb Key=Environment,Value=${ENVIRONMENT} \
        --region ${AWS_REGION})

    CLICKHOUSE_ALB_ARN=$(echo $CLICKHOUSE_ALB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')
    CLICKHOUSE_ALB_DNS=$(echo $CLICKHOUSE_ALB_RESPONSE | jq -r '.LoadBalancers[0].DNSName')
fi

CLICKHOUSE_CONFIG=$(cat <<EOF
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>information</level>
        <console>1</console>
    </logger>

    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <listen_host>0.0.0.0</listen_host>

    <max_connections>4096</max_connections>

    <!-- For 'Connection: keep-alive' in HTTP 1.1 -->
    <keep_alive_timeout>3</keep_alive_timeout>

    <!-- Maximum number of concurrent queries. -->
    <max_concurrent_queries>100</max_concurrent_queries>

    <max_server_memory_usage>0</max_server_memory_usage>

    <max_thread_pool_size>10000</max_thread_pool_size>

    <max_server_memory_usage_to_ram_ratio>0.9</max_server_memory_usage_to_ram_ratio>

    <total_memory_profiler_step>4194304</total_memory_profiler_step>

    <total_memory_tracker_sample_probability>0</total_memory_tracker_sample_probability>

    <uncompressed_cache_size>8589934592</uncompressed_cache_size>

    <mark_cache_size>5368709120</mark_cache_size>

    <mmap_cache_size>1000</mmap_cache_size>

    <!-- Cache size in bytes for compiled expressions.-->
    <compiled_expression_cache_size>134217728</compiled_expression_cache_size>

    <!-- Cache size in elements for compiled expressions.-->
    <compiled_expression_cache_elements_size>10000</compiled_expression_cache_elements_size>

    <!-- Path to data directory, with trailing slash. -->
    <path>/var/lib/clickhouse/</path>

    <!-- Path to temporary data for processing hard queries. -->
    <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>

    <!-- Directory with user provided files that are accessible by 'file' table function. -->
    <user_files_path>/var/lib/clickhouse/user_files/</user_files_path>

    <!-- Sources to read users, roles, access rights, profiles of settings, quotas. -->
    <user_directories>
        <users_xml>
            <!-- Path to configuration file with predefined users. -->
            <path>users.xml</path>
        </users_xml>
        <local_directory>
            <!-- Path to folder where users created by SQL commands are stored. -->
            <path>/var/lib/clickhouse/access/</path>
        </local_directory>
    </user_directories>

    <!-- Default profile of settings. -->
    <default_profile>default</default_profile>

    <!-- Comma-separated list of prefixes for user-defined settings. -->
    <custom_settings_prefixes></custom_settings_prefixes>

    <default_database>default</default_database>

    <mlock_executable>true</mlock_executable>

    <!-- Reallocate memory for machine code ("text") using huge pages. Highly experimental. -->
    <remap_executable>false</remap_executable>

    <!-- Reloading interval for embedded dictionaries, in seconds. Default: 3600. -->
    <builtin_dictionaries_reload_interval>3600</builtin_dictionaries_reload_interval>

    <!-- Maximum session timeout, in seconds. Default: 3600. -->
    <max_session_timeout>3600</max_session_timeout>

    <!-- Default session timeout, in seconds. Default: 60. -->
    <default_session_timeout>60</default_session_timeout>
    <allow_multiple_instances>1</allow_multiple_instances>
    <!--
        Asynchronous metric log contains values of metrics from
        system.asynchronous_metrics.
    -->
    <asynchronous_metric_log>
        <database>system</database>
        <table>asynchronous_metric_log</table>
        <!--
            Asynchronous metrics are updated once a minute, so there is
            no need to flush more often.
        -->
        <flush_interval_milliseconds>7000</flush_interval_milliseconds>
    </asynchronous_metric_log>
    <!-- Configuration of user defined executable functions -->
    <user_scripts_path>/var/lib/clickhouse/user_scripts/</user_scripts_path>
    <format_schema_path>/var/lib/clickhouse/format_schemas/</format_schema_path>
    <merge_tree_metadata_cache>
        <lru_cache_size>268435456</lru_cache_size>
        <continue_if_corrupted>true</continue_if_corrupted>
    </merge_tree_metadata_cache>
</clickhouse>
EOF
)

CLICKHOUSE_USERS=$(cat <<EOF
<?xml version="1.0"?>
<clickhouse>
    <profiles>
        <default>
            <max_memory_usage>10000000000</max_memory_usage>
            <load_balancing>random</load_balancing>
        </default>
        <readonly>
            <readonly>1</readonly>
        </readonly>
    </profiles>
    <users>
        <default>
            <password></password>

            <profile>default</profile>
            <quota>default</quota>
        </default>
    </users>

    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>
</clickhouse>
EOF
)

CONFIG_JS=$(cat <<EOF
window.APP_CONFIG = { 
    VITE_API_URL: "http://${GATEWAY_ALB_DNS}", 
    VITE_BASE_URL: "/albus", 
    VITE_PRIVATE_DEPLOYMENT: "ON", 
    VITE_AUTH_MODE: "NO_AUTH" 
};
EOF
)

# Convert Clickhouse configs to base64
CLICKHOUSE_CONFIG_B64=$(echo "${CLICKHOUSE_CONFIG}" | base64 -w 0)
CLICKHOUSE_USERS_B64=$(echo "${CLICKHOUSE_USERS}" | base64 -w 0)

# Create temporary directory and config files
TEMP_DIR=$(mktemp -d)

# Define NGINX configuration once
NGINX_CONF=$(cat <<EOF
server {
    listen 80;
    server_name localhost;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    location /config.js {
        alias /usr/share/nginx/html/config.js;
    }

    location /albus/ {
        rewrite ^/albus(.*)$ \$1 break;
        proxy_pass http://${BACKEND_ALB_DNS}:8080;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass_request_headers on;
        proxy_method \$request_method;
        proxy_pass_request_body on;
        proxy_set_header X-Original-URI \$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_body \$request_body;
        proxy_buffering off;
    }

    location /api/ {
        rewrite ^/api(.*)$ \$1 break;
        proxy_pass http://${GATEWAY_ALB_DNS};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass_request_headers on;
        proxy_method \$request_method;
        proxy_pass_request_body on;
        proxy_set_header X-Original-URI \$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_body \$request_body;
        proxy_buffering off;
    }

    error_page 404 /index.html;

    # Additional security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";
}
EOF
)

# Write the NGINX configuration to the temp directory
echo "${NGINX_CONF}" > "${TEMP_DIR}/nginx.conf"

# Write the config.js to the temp directory
echo "${CONFIG_JS}" > "${TEMP_DIR}/config.js"

# Update the frontend task definition to use base64 encoded configs
# Use platform-independent base64 encoding
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS version
    NGINX_CONF_B64=$(base64 < "${TEMP_DIR}/nginx.conf" | tr -d '\n')
    CONFIG_JS_B64=$(base64 < "${TEMP_DIR}/config.js" | tr -d '\n')
else
    # GNU/Linux version
    NGINX_CONF_B64=$(base64 -w 0 "${TEMP_DIR}/nginx.conf")
    CONFIG_JS_B64=$(base64 -w 0 "${TEMP_DIR}/config.js")
fi

FRONTEND_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-frontend",
    "containerDefinitions": [
        {
            "name": "config-init",
            "image": "busybox:latest",
            "essential": false,
            "command": [
                "sh",
                "-c",
                "echo '${NGINX_CONF_B64}' | base64 -d > /config/nginx.conf && echo '${CONFIG_JS_B64}' | base64 -d > /config/config.js"
            ],
            "mountPoints": [
                {
                    "sourceVolume": "config",
                    "containerPath": "/config",
                    "readOnly": false
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-frontend",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "config-init"
                }
            }
        },
        {
            "name": "frontend",
            "image": "docker.io/portkeyai/frontend:latest",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
            "dependsOn": [
                {
                    "containerName": "config-init",
                    "condition": "SUCCESS"
                }
            ],
            "command": [
                "/bin/sh",
                "-c",
                "echo \"Starting copy operations...\"; ls -l /config; cp /config/nginx.conf /etc/nginx/conf.d/default.conf && echo \"nginx.conf copied\" || echo \"Failed to copy nginx.conf\"; cp /config/config.js /usr/share/nginx/html/config.js && echo \"config.js copied\" || echo \"Failed to copy config.js\"; echo \"Copy operations completed\"; echo \"Starting Nginx...\"; exec nginx -g 'daemon off;'"
            ],
            "mountPoints": [
                {
                    "sourceVolume": "config",
                    "containerPath": "/config",
                    "readOnly": true
                }
            ],
            "portMappings": [
                {
                    "containerPort": 80,
                    "hostPort": 80,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [
                {
                    "name": "ENV",
                    "value": "${ENVIRONMENT}"
                },
                {
                    "name": "VITE_API_URL",
                    "value": "http://${GATEWAY_ALB_DNS}"
                },
                {
                    "name": "VITE_BASE_URL",
                    "value": "/albus"
                },
                {
                    "name": "VITE_PRIVATE_DEPLOYMENT",
                    "value": "ON"
                },
                {
                    "name": "VITE_AUTH_MODE",
                    "value": "NO_AUTH"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-frontend",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "volumes": [
        {
            "name": "config"
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

# Create MySQL Task Definition
MYSQL_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-mysql",
    "containerDefinitions": [
        {
            "name": "mysql",
            "image": "docker.io/mysql:8.1",
            "portMappings": [
                {
                    "containerPort": 3306,
                    "hostPort": 3306,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [
                {
                    "name": "MYSQL_ROOT_PASSWORD",
                    "value": "123456789"
                },
                {
                    "name": "MYSQL_PASSWORD",
                    "value": "123456789"
                },
                {
                    "name": "MYSQL_DATABASE",
                    "value": "portkey"
                },
                {
                    "name": "MYSQL_USER",
                    "value": "default"
                }
            ],
            "mountPoints": [
                {
                    "sourceVolume": "mysql-data",
                    "containerPath": "/var/lib/mysql",
                    "readOnly": false
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-mysql",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "volumes": [
        {
            "name": "mysql-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "${EFS_ID}",
                "transitEncryption": "ENABLED",
                "authorizationConfig": {
                    "accessPointId": "${MYSQL_AP}",
                    "iam": "ENABLED"
                }
            }
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

# Create Clickhouse Task Definition
CLICKHOUSE_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-clickhouse",
    "containerDefinitions": [
        {
            "name": "clickhouse-config-init",
            "image": "busybox:latest",
            "essential": false,
            "user": "0:0",
            "command": [
                "sh",
                "-c",
                "mkdir -p /var/lib/clickhouse /var/log/clickhouse-server /var/lib/clickhouse/tmp /var/lib/clickhouse/user_files /var/lib/clickhouse/format_schemas /var/lib/clickhouse/data && chmod -R 777 /var/lib/clickhouse /var/log/clickhouse-server && ls -l /var/lib/clickhouse && mkdir -p /etc/clickhouse-server && echo '${CLICKHOUSE_CONFIG_B64}' | base64 -d > /etc/clickhouse-server/config.xml && echo '${CLICKHOUSE_USERS_B64}' | base64 -d > /etc/clickhouse-server/users.xml && mkdir -p /etc/clickhouse-server/users.d && echo '<yandex><users><default><password>123456789</password><profile>default</profile><quota>default</quota></default></users></yandex>' > /etc/clickhouse-server/users.d/default-user.xml && chown -R 999:999 /etc/clickhouse-server && chmod -R 755 /etc/clickhouse-server"
            ],
            "mountPoints": [
                {
                    "sourceVolume": "config",
                    "containerPath": "/etc/clickhouse-server",
                    "readOnly": false
                },
                {
                    "sourceVolume": "clickhouse-data",
                    "containerPath": "/var/lib/clickhouse",
                    "readOnly": false
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-clickhouse",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "config-init"
                }
            }
        },
        {
            "name": "clickhouse",
            "image": "docker.io/clickhouse/clickhouse-server:latest",
            "dependsOn": [
                {
                    "containerName": "clickhouse-config-init",
                    "condition": "SUCCESS"
                }
            ],
            "user": "999:999",
            "portMappings": [
                {
                    "containerPort": 8123,
                    "hostPort": 8123,
                    "protocol": "tcp"
                },
                {
                    "containerPort": 9000,
                    "hostPort": 9000,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [
                {
                    "name": "CLICKHOUSE_DB",
                    "value": "default"
                },
                {
                    "name": "CLICKHOUSE_USER",
                    "value": "default"
                },
                {
                    "name": "CLICKHOUSE_PASSWORD",
                    "value": "123456789"
                },
                {
                    "name": "CLICKHOUSE_LOGGER_ERRORLOG",
                    "value": "/var/log/clickhouse-server/error.log"
                }
            ],
            "mountPoints": [
                {
                    "sourceVolume": "clickhouse-data",
                    "containerPath": "/var/lib/clickhouse",
                    "readOnly": false
                },
                {
                    "sourceVolume": "config",
                    "containerPath": "/etc/clickhouse-server",
                    "readOnly": false
                },
                {
                    "sourceVolume": "clickhouse-logs",
                    "containerPath": "/var/log/clickhouse-server",
                    "readOnly": false
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-clickhouse",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "volumes": [
        {
            "name": "clickhouse-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "${EFS_ID}",
                "transitEncryption": "ENABLED",
                "authorizationConfig": {
                    "accessPointId": "${CLICKHOUSE_AP}",
                    "iam": "ENABLED"
                }
            }
        },
        {
            "name": "config",
            "efsVolumeConfiguration": {
                "fileSystemId": "${EFS_ID}",
                "transitEncryption": "ENABLED",
                "authorizationConfig": {
                    "accessPointId": "${CLICKHOUSE_AP}",
                    "iam": "ENABLED"
                }
            }
        },
        {
            "name": "clickhouse-logs",
            "efsVolumeConfiguration": {
                "fileSystemId": "${EFS_ID}",
                "transitEncryption": "ENABLED",
                "authorizationConfig": {
                    "accessPointId": "${CLICKHOUSE_AP}",
                    "iam": "ENABLED"
                }
            }
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "2048",
    "memory": "4096",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

# Create Backend Task Definition
BACKEND_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-backend",
    "containerDefinitions": [
        {
            "name": "backend",
            "image": "docker.io/portkeyai/backend:latest",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
            "environment": [
                {
                    "name": "PORT",
                    "value": "8080"
                },
                {
                    "name": "AUTH_MODE",
                    "value": "NO_AUTH"
                },
                {
                    "name": "JWT_PRIVATE_KEY",
                    "value": "randomstring"
                },
                {
                    "name": "PRIVATE_DEPLOYMENT",
                    "value": "ON"
                },
                {
                    "name": "SERVICE_NAME",
                    "value": "portkey-backend"
                },
                {
                    "name": "GATEWAY_BASE_URL",
                    "value": "http://${GATEWAY_ALB_DNS}"
                },
                {
                    "name": "GATEWAY_CACHE_MODE",
                    "value": "SELF"
                },
                {
                    "name": "CONTROL_PLANE_URL",
                    "value": "http://${FRONTEND_ALB_DNS}"
                },
                {
                    "name": "CONTROL_PANEL_URL",
                    "value": "http://${FRONTEND_ALB_DNS}"
                },
                {
                    "name": "ALBUS_BASE_URL",
                    "value": "http://${FRONTEND_ALB_DNS}/albus"
                },
                {
                    "name": "ENV",
                    "value": "${ENVIRONMENT}"
                },
                {
                    "name": "POLYJUICE_FINETUNE_ENDPOINT",
                    "value": "http://${DATASERVICE_ALB_DNS}"
                },
                {
                    "name": "LOG_STORE",
                    "value": "s3"
                },
                {
                    "name": "LOG_STORE_ACCESS_KEY",
                    "value": "${AWS_ACCESS_KEY_ID}"
                },
                {
                    "name": "LOG_STORE_SECRET_KEY",
                    "value": "${AWS_SECRET_ACCESS_KEY}"
                },
                {
                    "name": "LOG_STORE_REGION",
                    "value": "${AWS_REGION}"
                },
                {
                    "name": "LOG_STORE_GENERATIONS_BUCKET",
                    "value": "${BUCKET_NAME}"
                },
                {
                    "name": "LOG_STORE_BASEPATH",
                    "value": "generations"
                },
                {
                    "name": "FINETUNES_BUCKET",
                    "value": "${BUCKET_NAME}"
                },
                {
                    "name": "LOG_EXPORTS_BUCKET",
                    "value": "${BUCKET_NAME}"
                },
                {
                    "name": "CACHE_STORE",
                    "value": "redis_store"
                },
                {
                    "name": "REDIS_URL",
                    "value": "redis://${REDIS_NLB_DNS}:6379"
                },
                {
                    "name": "REDIS_TLS_ENABLED",
                    "value": "false"
                },
                {
                    "name": "REDIS_MODE",
                    "value": "single"
                },
                {
                    "name": "DB_HOST",
                    "value": "${MYSQL_NLB_DNS}"
                },
                {
                    "name": "DB_PORT",
                    "value": "3306"
                },
                {
                    "name": "DB_USER",
                    "value": "default"
                },
                {
                    "name": "DB_PASS",
                    "value": "123456789"
                },
                {
                    "name": "DB_NAME",
                    "value": "portkey"
                },
                {
                    "name": "CLICKHOUSE_HOST",
                    "value": "${CLICKHOUSE_ALB_DNS}"
                },
                {
                    "name": "CLICKHOUSE_PORT",
                    "value": "8123"
                },
                {
                    "name": "CLICKHOUSE_DATABASE",
                    "value": "default"
                },
                {
                    "name": "CLICKHOUSE_NATIVE_PORT",
                    "value": "9000"
                },
                {
                    "name": "CLICKHOUSE_USER",
                    "value": "default"
                },
                {
                    "name": "CLICKHOUSE_PASSWORD",
                    "value": "123456789"
                },
                {
                    "name": "CLICKHOUSE_TLS",
                    "value": "false"
                }
            ],
            "portMappings": [
                {
                    "containerPort": 8080,
                    "hostPort": 8080,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "command": [
                "/bin/sh", 
                "-c", 
                "/app/docker-entrypoint.sh && npx knex migrate:latest --env local && npx knex seed:run --env local && node ch_init.js && pm2-runtime src/server.js"
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-backend",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "1024",
    "memory": "4096",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

# Create Gateway Task Definition
GATEWAY_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-gateway",
    "containerDefinitions": [
        {
            "name": "gateway",
            "image": "docker.io/portkeyai/gateway_enterprise:1.9.6",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
            "environment": [
                {
                    "name": "PORT",
                    "value": "80"
                },
                {
                    "name": "LOG_STORE",
                    "value": "control_plane"
                },
                {
                    "name": "ANALYTICS_STORE",
                    "value": "control_plane"
                },
                {
                    "name": "PORTKEY_CLIENT_AUTH",
                    "value": "client_auth-PRIVATE_SEVICE"
                },
                {
                    "name": "PRIVATE_DEPLOYMENT",
                    "value": "ON"
                },
                {
                    "name": "SERVICE_NAME",
                    "value": "portkey-gateway"
                },
                {
                    "name": "GATEWAY_CACHE_MODE",
                    "value": "SELF"
                },
                {
                    "name": "ENV",
                    "value": "${ENVIRONMENT}"
                },
                {
                    "name": "ALBUS_BASEPATH",
                    "value": "http://${BACKEND_ALB_DNS}:8080"
                },
                {
                    "name": "CACHE_STORE",
                    "value": "redis_store"
                },
                {
                    "name": "REDIS_URL",
                    "value": "redis://${REDIS_NLB_DNS}:6379"
                },
                {
                    "name": "REDIS_TLS_ENABLED",
                    "value": "false"
                },
                {
                    "name": "REDIS_MODE",
                    "value": "single"
                }
            ],
            "portMappings": [
                {
                    "containerPort": 80,
                    "hostPort": 80,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-gateway",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

# Create Redis Task Definition
REDIS_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-redis",
    "containerDefinitions": [
        {
            "name": "redis",
            "image": "docker.io/redis:alpine",
            "portMappings": [
                {
                    "containerPort": 6379,
                    "hostPort": 6379,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "mountPoints": [
                {
                    "sourceVolume": "redis-data",
                    "containerPath": "/data",
                    "readOnly": false
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-redis",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "volumes": [
        {
            "name": "redis-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "${EFS_ID}",
                "transitEncryption": "ENABLED",
                "authorizationConfig": {
                    "accessPointId": "${REDIS_AP}",
                    "iam": "ENABLED"
                }
            }
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

# Create Data Service Task Definition
DATA_SERVICE_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-dataservice",
    "containerDefinitions": [
        {
            "name": "dataservice",
            "image": "docker.io/portkeyai/data-service:latest",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
            "environment": [
                {
                    "name": "PORT",
                    "value": "80"
                },
                {
                    "name": "PRIVATE_DEPLOYMENT",
                    "value": "ON"
                },
                {
                    "name": "SERVICE_NAME",
                    "value": "portkey-dataservice"
                },
                {
                    "name": "ENV",
                    "value": "${ENVIRONMENT}"
                },
                {
                    "name": "LOG_STORE",
                    "value": "s3"
                },
                {
                    "name": "LOG_STORE_ACCESS_KEY",
                    "value": "${AWS_ACCESS_KEY_ID}"
                },
                {
                    "name": "LOG_STORE_SECRET_KEY",
                    "value": "${AWS_SECRET_ACCESS_KEY}"
                },
                {
                    "name": "LOG_STORE_REGION",
                    "value": "${AWS_REGION}"
                },
                {
                    "name": "LOG_STORE_GENERATIONS_BUCKET",
                    "value": "${BUCKET_NAME}"
                },
                {
                    "name": "LOG_STORE_BASEPATH",
                    "value": "generations"
                },
                {
                    "name": "FINETUNES_BUCKET",
                    "value": "${BUCKET_NAME}"
                },
                {
                    "name": "LOG_EXPORTS_BUCKET",
                    "value": "${BUCKET_NAME}"
                },
                {
                    "name": "CACHE_STORE",
                    "value": "redis_store"
                },
                {
                    "name": "REDIS_URL",
                    "value": "redis://${REDIS_NLB_DNS}:6379"
                },
                {
                    "name": "REDIS_TLS_ENABLED",
                    "value": "false"
                },
                {
                    "name": "REDIS_MODE",
                    "value": "single"
                },
                {
                    "name": "ANALYTICS_STORE",
                    "value": "clickhouse"
                },
                {
                    "name": "CLICKHOUSE_HOST",
                    "value": "${CLICKHOUSE_ALB_DNS}"
                },
                {
                    "name": "CLICKHOUSE_PORT",
                    "value": "8123"
                },
                {
                    "name": "CLICKHOUSE_DB",
                    "value": "default"
                },
                {
                    "name": "CLICKHOUSE_NATIVE_PORT",
                    "value": "9000"
                },
                {
                    "name": "CLICKHOUSE_USER",
                    "value": "default"
                },
                {
                    "name": "CLICKHOUSE_PASSWORD",
                    "value": "123456789"
                },
                {
                    "name": "CLICKHOUSE_TLS",
                    "value": "false"
                }
            ],
            "portMappings": [
                {
                    "containerPort": 80,
                    "hostPort": 80,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-dataservice",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

# Create Data Service Target Group
EXISTING_DATASERVICE_TG=$(aws elbv2 describe-target-groups \
    --names portkey-dataservice-tg \
    --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Using existing data service target group..."
    DATASERVICE_TG_ARN=$(echo $EXISTING_DATASERVICE_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new data service target group..."
    DATASERVICE_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-dataservice-tg \
        --protocol HTTP \
        --port 80 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-path "/health" \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    DATASERVICE_TG_ARN=$(echo $DATASERVICE_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

echo "Creating CloudWatch log groups..."
LOG_GROUPS=(
    "/ecs/portkey-frontend"
    "/ecs/portkey-gateway"
    "/ecs/portkey-backend"
    "/ecs/portkey-redis"
    "/ecs/portkey-clickhouse"
    "/ecs/portkey-mysql"
    "/ecs/portkey-dataservice"
)

for LOG_GROUP in "${LOG_GROUPS[@]}"; do
    # Check if log group exists
    if aws logs describe-log-groups --log-group-name-prefix ${LOG_GROUP} --region ${AWS_REGION} | grep -q "logGroupName"; then
        echo "Log group ${LOG_GROUP} already exists"
    else
        echo "Creating log group ${LOG_GROUP}"
        aws logs create-log-group \
            --log-group-name ${LOG_GROUP} \
            --region ${AWS_REGION}
        
        # Set retention policy for new log groups
        aws logs put-retention-policy \
            --log-group-name ${LOG_GROUP} \
            --retention-in-days 14 \
            --region ${AWS_REGION}
    fi
done

# Register all task definitions
echo "Registering task definitions..."
FRONTEND_TASK_DEF_ARN=$(echo "${FRONTEND_TASK_DEFINITION}" | \
    aws ecs register-task-definition \
    --cli-input-json "$(cat -)" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

BACKEND_TASK_DEF_ARN=$(echo "${BACKEND_TASK_DEFINITION}" | \
    aws ecs register-task-definition \
    --cli-input-json "$(cat -)" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

# Register gateway task definition  
GATEWAY_TASK_DEF_ARN=$(echo "${GATEWAY_TASK_DEFINITION}" | \
    aws ecs register-task-definition \
    --cli-input-json "$(cat -)" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

# Register redis task definition
REDIS_TASK_DEF_ARN=$(echo "${REDIS_TASK_DEFINITION}" | \
    aws ecs register-task-definition \
    --cli-input-json "$(cat -)" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

MYSQL_TASK_DEF_ARN=$(echo "${MYSQL_TASK_DEFINITION}" | \
    aws ecs register-task-definition \
    --cli-input-json "$(cat -)" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

CLICKHOUSE_TASK_DEF_ARN=$(echo "${CLICKHOUSE_TASK_DEFINITION}" | \
    aws ecs register-task-definition \
    --cli-input-json "$(cat -)" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

DATA_SERVICE_TASK_DEF_ARN=$(echo "${DATA_SERVICE_TASK_DEFINITION}" | \
    aws ecs register-task-definition \
    --cli-input-json "$(cat -)" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

echo "Task definitions registered successfully: "
echo "Frontend: ${FRONTEND_TASK_DEF_ARN}"
echo "Backend: ${BACKEND_TASK_DEF_ARN}"
echo "Gateway: ${GATEWAY_TASK_DEF_ARN}"

echo "Setting up target groups..."

# Check/Create Frontend Target Group
echo "Setting up frontend target group..."
EXISTING_FRONTEND_TG=$(aws elbv2 describe-target-groups \
    --names portkey-frontend-tg \
    --region ${AWS_REGION})

if [ $? -eq 0 ]; then
    echo "Using existing frontend target group..."
    FRONTEND_TG_ARN=$(echo $EXISTING_FRONTEND_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new frontend target group..."
    FRONTEND_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-frontend-tg \
        --protocol HTTP \
        --port 80 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-path "/health" \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    FRONTEND_TG_ARN=$(echo $FRONTEND_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

# Check/Create Backend Target Group
echo "Setting up backend target group..."
EXISTING_BACKEND_TG=$(aws elbv2 describe-target-groups \
    --names portkey-backend-tg \
    --region ${AWS_REGION})

if [ $? -eq 0 ]; then
    echo "Using existing backend target group..."
    BACKEND_TG_ARN=$(echo $EXISTING_BACKEND_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new backend target group..."
    BACKEND_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-backend-tg \
        --protocol HTTP \
        --port 8080 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-path "/health" \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    BACKEND_TG_ARN=$(echo $BACKEND_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

# Check/Create Gateway Target Group
echo "Setting up gateway target group..."
EXISTING_GATEWAY_TG=$(aws elbv2 describe-target-groups \
    --names portkey-gateway-tg \
    --region ${AWS_REGION})

if [ $? -eq 0 ]; then
    echo "Using existing gateway target group..."
    GATEWAY_TG_ARN=$(echo $EXISTING_GATEWAY_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new gateway target group..."
    GATEWAY_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-gateway-tg \
        --protocol HTTP \
        --port 80 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-path "/v1/health" \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    GATEWAY_TG_ARN=$(echo $GATEWAY_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

# Check/Create Redis Target Group
echo "Setting up redis target group..."
EXISTING_REDIS_TG=$(aws elbv2 describe-target-groups \
    --names portkey-redis-tg \
    --region ${AWS_REGION})

if [ $? -eq 0 ]; then
    echo "Using existing redis target group..."
    REDIS_TG_ARN=$(echo $EXISTING_REDIS_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new redis target group..."
    REDIS_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-redis-tg \
        --protocol TCP \
        --port 6379 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-protocol TCP \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 10 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    REDIS_TG_ARN=$(echo $REDIS_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

# Check/Create MySQL Target Group
echo "Setting up MySQL target group..."
EXISTING_MYSQL_TG=$(aws elbv2 describe-target-groups \
    --names portkey-mysql-tg \
    --region ${AWS_REGION})

if [ $? -eq 0 ]; then
    echo "Using existing MySQL target group..."
    MYSQL_TG_ARN=$(echo $EXISTING_MYSQL_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new MySQL target group..."
    MYSQL_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-mysql-tg \
        --protocol TCP \
        --port 3306 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-protocol TCP \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 10 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    MYSQL_TG_ARN=$(echo $MYSQL_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

# Check/Create Clickhouse Target Group
echo "Setting up Clickhouse target group..."
EXISTING_CLICKHOUSE_TG=$(aws elbv2 describe-target-groups \
    --names portkey-clickhouse-tg \
    --region ${AWS_REGION})

if [ $? -eq 0 ]; then
    echo "Using existing Clickhouse target group..."
    CLICKHOUSE_TG_ARN=$(echo $EXISTING_CLICKHOUSE_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new Clickhouse target group..."
    CLICKHOUSE_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-clickhouse-tg \
        --protocol HTTP \
        --port 8123 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-path "/ping" \
        --health-check-interval-seconds 60 \
        --health-check-timeout-seconds 30 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    CLICKHOUSE_TG_ARN=$(echo $CLICKHOUSE_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

# Check/Create Data Service Target Group
echo "Setting up data service target group..."
EXISTING_DATASERVICE_TG=$(aws elbv2 describe-target-groups \
    --names portkey-dataservice-tg \
    --region ${AWS_REGION})

if [ $? -eq 0 ]; then
    echo "Using existing data service target group..."
    DATASERVICE_TG_ARN=$(echo $EXISTING_DATASERVICE_TG | jq -r '.TargetGroups[0].TargetGroupArn')
else
    echo "Creating new data service target group..."
    DATASERVICE_TG_RESPONSE=$(aws elbv2 create-target-group \
        --name portkey-dataservice-tg \
        --protocol HTTP \
        --port 80 \
        --vpc-id ${VPC_ID} \
        --target-type ip \
        --health-check-path "/health" \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region ${AWS_REGION})

    DATASERVICE_TG_ARN=$(echo $DATASERVICE_TG_RESPONSE | jq -r '.TargetGroups[0].TargetGroupArn')
fi

# Create listeners for each ALB
echo "Creating ALB listeners..."

# Frontend Listener
aws elbv2 create-listener \
    --load-balancer-arn ${FRONTEND_ALB_ARN} \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=${FRONTEND_TG_ARN} \
    --region ${AWS_REGION}

# Backend Listener
aws elbv2 create-listener \
    --load-balancer-arn ${BACKEND_ALB_ARN} \
    --protocol HTTP \
    --port 8080 \
    --default-actions Type=forward,TargetGroupArn=${BACKEND_TG_ARN} \
    --region ${AWS_REGION}

# Gateway Listener
aws elbv2 create-listener \
    --load-balancer-arn ${GATEWAY_ALB_ARN} \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=${GATEWAY_TG_ARN} \
    --region ${AWS_REGION}

# Redis Listener (TCP)
aws elbv2 create-listener \
    --load-balancer-arn ${REDIS_NLB_ARN} \
    --protocol TCP \
    --port 6379 \
    --default-actions Type=forward,TargetGroupArn=${REDIS_TG_ARN} \
    --region ${AWS_REGION}

# Create MySQL and Clickhouse NLB listeners
aws elbv2 create-listener \
    --load-balancer-arn ${MYSQL_NLB_ARN} \
    --protocol TCP \
    --port 3306 \
    --default-actions Type=forward,TargetGroupArn=${MYSQL_TG_ARN} \
    --region ${AWS_REGION}

# Create Data Service Listener
aws elbv2 create-listener \
    --load-balancer-arn ${DATASERVICE_ALB_ARN} \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=${DATASERVICE_TG_ARN} \
    --region ${AWS_REGION}

# Create Clickhouse ALB listener
aws elbv2 create-listener \
    --load-balancer-arn ${CLICKHOUSE_ALB_ARN} \
    --protocol HTTP \
    --port 8123 \
    --default-actions Type=forward,TargetGroupArn=${CLICKHOUSE_TG_ARN} \
    --region ${AWS_REGION}

echo "Waiting for listeners to be active..."
sleep 10

# Create or update Frontend service
echo "Deploying frontend service..."
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services "portkey-frontend" \
    --region ${AWS_REGION} \
    --query 'services[0].status' \
    --output text)

if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
    echo "Updating existing frontend service..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service "portkey-frontend" \
        --task-definition ${FRONTEND_TASK_DEF_ARN} \
        --force-new-deployment \
        --region ${AWS_REGION}
else
    echo "Creating new frontend service..."
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name "portkey-frontend" \
        --task-definition ${FRONTEND_TASK_DEF_ARN} \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":${SUBNET_LIST_JSON},\"securityGroups\":[\"${PORTKEY_SECURITY_GROUP}\"],\"assignPublicIp\":\"ENABLED\"}}" \
        --load-balancers "targetGroupArn=${FRONTEND_TG_ARN},containerName=frontend,containerPort=80" \
        --region ${AWS_REGION}
fi

# Create or update Backend service
echo "Deploying backend service..."
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services "portkey-backend" \
    --region ${AWS_REGION} \
    --query 'services[0].status' \
    --output text)

if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
    echo "Updating existing backend service..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service "portkey-backend" \
        --task-definition ${BACKEND_TASK_DEF_ARN} \
        --force-new-deployment \
        --region ${AWS_REGION}
else
    echo "Creating new backend service..."
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name "portkey-backend" \
        --task-definition ${BACKEND_TASK_DEF_ARN} \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":${SUBNET_LIST_JSON},\"securityGroups\":[\"${PORTKEY_SECURITY_GROUP}\"],\"assignPublicIp\":\"ENABLED\"}}" \
        --load-balancers "targetGroupArn=${BACKEND_TG_ARN},containerName=backend,containerPort=8080" \
        --region ${AWS_REGION}
fi

# Create or update Gateway service
echo "Deploying gateway service..."
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services "portkey-gateway" \
    --region ${AWS_REGION} \
    --query 'services[0].status' \
    --output text)

if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
    echo "Updating existing gateway service..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service "portkey-gateway" \
        --task-definition ${GATEWAY_TASK_DEF_ARN} \
        --force-new-deployment \
        --region ${AWS_REGION}
else
    echo "Creating new gateway service..."
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name "portkey-gateway" \
        --task-definition ${GATEWAY_TASK_DEF_ARN} \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":${SUBNET_LIST_JSON},\"securityGroups\":[\"${PORTKEY_SECURITY_GROUP}\"],\"assignPublicIp\":\"ENABLED\"}}" \
        --load-balancers "targetGroupArn=${GATEWAY_TG_ARN},containerName=gateway,containerPort=80" \
        --region ${AWS_REGION}
fi

# Create or update Redis service
echo "Deploying redis service..."
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services "portkey-redis" \
    --region ${AWS_REGION} \
    --query 'services[0].status' \
    --output text)

if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
    echo "Updating existing redis service..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service "portkey-redis" \
        --task-definition ${REDIS_TASK_DEF_ARN} \
        --force-new-deployment \
        --region ${AWS_REGION}
else
    echo "Creating new redis service..."
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name "portkey-redis" \
        --task-definition ${REDIS_TASK_DEF_ARN} \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":${SUBNET_LIST_JSON},\"securityGroups\":[\"${PORTKEY_SECURITY_GROUP}\"],\"assignPublicIp\":\"ENABLED\"}}" \
        --load-balancers "targetGroupArn=${REDIS_TG_ARN},containerName=redis,containerPort=6379" \
        --region ${AWS_REGION}
fi

# Create or update MySQL service
echo "Deploying MySQL service..."
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services "portkey-mysql" \
    --region ${AWS_REGION} \
    --query 'services[0].status' \
    --output text)

if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
    echo "Updating existing MySQL service..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service "portkey-mysql" \
        --task-definition ${MYSQL_TASK_DEF_ARN} \
        --force-new-deployment \
        --region ${AWS_REGION}
else
    echo "Creating new MySQL service..."
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name "portkey-mysql" \
        --task-definition ${MYSQL_TASK_DEF_ARN} \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":${SUBNET_LIST_JSON},\"securityGroups\":[\"${PORTKEY_SECURITY_GROUP}\"],\"assignPublicIp\":\"ENABLED\"}}" \
        --load-balancers "targetGroupArn=${MYSQL_TG_ARN},containerName=mysql,containerPort=3306" \
        --region ${AWS_REGION}
fi

# Create or update Clickhouse service
echo "Deploying Clickhouse service..."
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services "portkey-clickhouse" \
    --region ${AWS_REGION} \
    --query 'services[0].status' \
    --output text)

if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
    echo "Updating existing Clickhouse service..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service "portkey-clickhouse" \
        --task-definition ${CLICKHOUSE_TASK_DEF_ARN} \
        --force-new-deployment \
        --region ${AWS_REGION}
else
    echo "Creating new Clickhouse service..."
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name "portkey-clickhouse" \
        --task-definition ${CLICKHOUSE_TASK_DEF_ARN} \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":${SUBNET_LIST_JSON},\"securityGroups\":[\"${PORTKEY_SECURITY_GROUP}\"],\"assignPublicIp\":\"ENABLED\"}}" \
        --load-balancers "targetGroupArn=${CLICKHOUSE_TG_ARN},containerName=clickhouse,containerPort=8123" \
        --region ${AWS_REGION}
fi

# Create or update Data Service
echo "Deploying data service..."
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services "portkey-dataservice" \
    --region ${AWS_REGION} \
    --query 'services[0].status' \
    --output text)

if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
    echo "Updating existing data service..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service "portkey-dataservice" \
        --task-definition ${DATA_SERVICE_TASK_DEF_ARN} \
        --force-new-deployment \
        --region ${AWS_REGION}
else
    echo "Creating new data service..."
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name "portkey-dataservice" \
        --task-definition ${DATA_SERVICE_TASK_DEF_ARN} \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":${SUBNET_LIST_JSON},\"securityGroups\":[\"${PORTKEY_SECURITY_GROUP}\"],\"assignPublicIp\":\"ENABLED\"}}" \
        --load-balancers "targetGroupArn=${DATASERVICE_TG_ARN},containerName=dataservice,containerPort=80" \
        --region ${AWS_REGION}
fi

# Update resources.json to include data service
cat > portkey-resources.json << EOF
{
    "cluster_name": "${CLUSTER_NAME}",
    "security_groups": {
        "portkey_sg": "${PORTKEY_SECURITY_GROUP}",
        "efs_sg": "${EFS_SECURITY_GROUP}"
    },
    "efs": {
        "filesystem_id": "${EFS_ID}",
        "access_points": {
            "mysql": "${MYSQL_AP}",
            "redis": "${REDIS_AP}",
            "clickhouse": "${CLICKHOUSE_AP}"
        }
    },
    "target_groups": {
        "frontend": "${FRONTEND_TG_ARN}",
        "backend": "${BACKEND_TG_ARN}",
        "gateway": "${GATEWAY_TG_ARN}",
        "redis": "${REDIS_TG_ARN}",
        "mysql": "${MYSQL_TG_ARN}",
        "clickhouse": "${CLICKHOUSE_TG_ARN}",
        "dataservice": "${DATASERVICE_TG_ARN}"
    },
    "load_balancers": {
        "frontend": "${FRONTEND_ALB_ARN}",
        "backend": "${BACKEND_ALB_ARN}",
        "gateway": "${GATEWAY_ALB_ARN}",
        "redis": "${REDIS_NLB_ARN}",
        "mysql": "${MYSQL_NLB_ARN}",
        "clickhouse": "${CLICKHOUSE_ALB_ARN}",
        "dataservice": "${DATASERVICE_ALB_ARN}"
    },
    "load_balancer_dns": {
        "frontend": "${FRONTEND_ALB_DNS}",
        "backend": "${BACKEND_ALB_DNS}",
        "gateway": "${GATEWAY_ALB_DNS}",
        "redis": "${REDIS_NLB_DNS}",
        "mysql": "${MYSQL_NLB_DNS}",
        "clickhouse": "${CLICKHOUSE_ALB_DNS}",
        "dataservice": "${DATASERVICE_ALB_DNS}"
    },
    "log_groups": [
        "/ecs/portkey-frontend",
        "/ecs/portkey-gateway",
        "/ecs/portkey-backend",
        "/ecs/portkey-redis",
        "/ecs/portkey-clickhouse",
        "/ecs/portkey-mysql"
    ],
    "s3_bucket": {
        "name": "${BUCKET_NAME}",
        "arn": "arn:aws:s3:::${BUCKET_NAME}"
    }
}
EOF

echo "Resource information saved to portkey-resources.json"
echo "Load Balancer DNS Names:"
echo "Frontend: ${FRONTEND_ALB_DNS}"
echo "Backend: ${BACKEND_ALB_DNS}"
echo "Gateway: ${GATEWAY_ALB_DNS}"

# Clean up temp directory
rm -rf "${TEMP_DIR}"
