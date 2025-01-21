
# Read configuration from portkey.env
if [ -f "portkey.env" ]; then
    source portkey.env
else
    echo "Error: portkey.env file not found"
    exit 1
fi

#Enviroment might not be needed as default is used in EC2
ENVIRONMENT=portkey-poc-innovation-lab
DOCKER_USERNAME=throwaway.docker.hub@gmail.com
DOCKER_PASSWORD=throwaway@123
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=196856463470
VPC_ID=vpc-02d65f45df09dcd82
SUBNET_IDS=""

#ECS Cluster
CLUSTER_NAME=portkey-ai
TASK_ROLE_ARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole
EXECUTION_ROLE_ARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole

echo "Creating Docker Hub Portkey credentials in Secrets Manager..."
DOCKER_CREDS_JSON=$(cat <<EOF
{
    "username": "${DOCKER_USERNAME}",
    "password": "${DOCKER_PASSWORD}"
}
EOF
)

DOCKER_CREDENTIALS_RESPONSE=$(aws secretsmanager create-secret \
    --name "portkey/docker-credentials" \
    --description "Docker Hub credentials for Portkey images" \
    --secret-string "${DOCKER_CREDS_JSON}" \
    --tags Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION})

DOCKER_CREDENTIALS_SECRET_ARN=$(echo $DOCKER_CREDENTIALS_RESPONSE | jq -r '.ARN')

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

# Frontend Security Group
PORTKEY_SG_RESPONSE=$(aws ec2 create-security-group \
    --group-name portkey-sg \
    --description "Security group for Portkey" \
    --vpc-id ${VPC_ID} \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=portkey-sg}, {Key=Environment,Value=${ENVIRONMENT}}]' \
    --region ${AWS_REGION})

PORTKEY_SECURITY_GROUP=$(echo $PORTKEY_SG_RESPONSE | jq -r '.GroupId')

aws ec2 authorize-security-group-ingress \
    --group-id ${PORTKEY_SECURITY_GROUP} \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 \
    --region ${AWS_REGION}

# EFS Security Group
EFS_SG_RESPONSE=$(aws ec2 create-security-group \
    --group-name portkey-efs-sg \
    --description "Security group for Portkey EFS" \
    --vpc-id ${VPC_ID} \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=portkey-efs-sg}, {Key=Environment,Value=${ENVIRONMENT}}]' \
    --region ${AWS_REGION})

EFS_SECURITY_GROUP=$(echo $EFS_SG_RESPONSE | jq -r '.GroupId')

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

# Create EFS file system
echo "Creating EFS file system for databases..."
EFS_RESPONSE=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value=portkey-storage Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION})

# Create EFS file system
echo "Creating EFS file system..."
EFS_RESPONSE=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value=portkey-storage Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION})

EFS_ID=$(echo $EFS_RESPONSE | jq -r '.FileSystemId')

# Create mount targets in each subnet
for SUBNET in ${SUBNET_IDS//,/ }; do
    aws efs create-mount-target \
        --file-system-id $EFS_ID \
        --subnet-id $SUBNET \
        --security-groups ${EFS_SECURITY_GROUP} \
        --region ${AWS_REGION}
done

# Create EFS access points
MYSQL_AP=$(aws efs create-access-point \
    --file-system-id $EFS_ID \
    --posix-user Uid=999,Gid=999 \
    --root-directory Path=/mysql,CreationInfo="{OwnerUid=999,OwnerGid=999,Permissions=755}" \
    --tags Key=Name,Value=portkey-mysql Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION} | jq -r '.AccessPointId')

REDIS_AP=$(aws efs create-access-point \
    --file-system-id $EFS_ID \
    --posix-user Uid=999,Gid=999 \
    --root-directory Path=/redis,CreationInfo="{OwnerUid=999,OwnerGid=999,Permissions=755}" \
    --tags Key=Name,Value=portkey-redis Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION} | jq -r '.AccessPointId')

CLICKHOUSE_AP=$(aws efs create-access-point \
    --file-system-id $EFS_ID \
    --posix-user Uid=999,Gid=999 \
    --root-directory Path=/clickhouse,CreationInfo="{OwnerUid=999,OwnerGid=999,Permissions=755}" \
    --tags Key=Name,Value=portkey-clickhouse Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION} | jq -r '.AccessPointId')

# Task definition for frontend
FRONTEND_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-frontend",
    "containerDefinitions": [
        {
            "name": "frontend",
            "image": "docker.io/portkeyai/frontend:latest",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
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

# task definition for gaetway and backend
GATEWAY_TASK_DEFINITION=$(cat <<EOF
{
    "family": "portkey-gateway",
    "containerDefinitions": [
        {
            "name": "gateway",
            "image": "docker.io/portkeyai/gateway_enterprise:latest",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
            "portMappings": [
                {
                    "containerPort": 8787,
                    "hostPort": 8787,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [
                {
                    "name": "ENV",
                    "value": "${ENVIRONMENT}"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-gateway",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        },
        {
            "name": "backend",
            "image": "docker.io/portkeyai/backend:latest",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
            "portMappings": [
                {
                    "containerPort": 8080,
                    "protocol": "tcp"
                }
            ],
            "essential": false,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-backend",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        },
        {
            "name": "dataservice",
            "image": "docker.io/portkeyai/data-service:latest",
            "repositoryCredentials": {
                "credentialsParameter": "${DOCKER_CREDENTIALS_SECRET_ARN}"
            },
            "portMappings": [
                {
                    "containerPort": 8081,
                    "protocol": "tcp"
                }
            ],
            "essential": false,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/portkey-dataservice",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        },
       {
            "name": "redis",
            "image": "docker.io/redis:alpine",
            "portMappings": [
                {
                    "containerPort": 6379,
                    "protocol": "tcp"
                }
            ],
            "essential": false,
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
        },
        {
            "name": "mysql",
            "image": "docker.io/mysql:8.1",
            "portMappings": [
                {
                    "containerPort": 3306,
                    "protocol": "tcp"
                }
            ],
            "essential": false,
            "environment": [
                {
                    "name": "MYSQL_ROOT_PASSWORD",
                    "value": "${MYSQL_ROOT_PASSWORD}"
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
        },
        {
            "name": "clickhouse",
            "image": "docker.io/clickhouse/clickhouse-server:latest",
            "portMappings": [
                {
                    "containerPort": 8123,
                    "protocol": "tcp"
                },
                {
                    "containerPort": 9000,
                    "protocol": "tcp"
                }
            ],
            "essential": false,
            "mountPoints": [
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
        },
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
        },
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
        }
    ],
    "taskRoleArn": "${TASK_ROLE_ARN}",
    "executionRoleArn": "${EXECUTION_ROLE_ARN}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "2048",
    "memory": "8192",
    "runtimePlatform": {
        "operatingSystemFamily": "LINUX",
        "cpuArchitecture": "ARM64"
    }
}
EOF
)

echo "Creating CloudWatch log groups..."
LOG_GROUPS=(
    "/ecs/portkey-frontend"
    "/ecs/portkey-gateway"
    "/ecs/portkey-backend"
    "/ecs/portkey-dataservice"
    "/ecs/portkey-redis"
    "/ecs/portkey-mysql"
    "/ecs/portkey-clickhouse"
)

for LOG_GROUP in "${LOG_GROUPS[@]}"; do
    aws logs create-log-group \
        --log-group-name ${LOG_GROUP} \
        --region ${AWS_REGION}
    
    # Optionally set retention policy (e.g., 14 days)
    aws logs put-retention-policy \
        --log-group-name ${LOG_GROUP} \
        --retention-in-days 14 \
        --region ${AWS_REGION}
done

echo "Registering task definition for frontend..."
aws ecs register-task-definition --cli-input-json file://frontend-task-definition.json

echo "Registering task definition for gateway..."
aws ecs register-task-definition --cli-input-json file://gateway-task-definition.json

echo "Creating target groups..."

# Frontend target group
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

# Gateway target group
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

# Create Frontend ALB
echo "Creating Frontend ALB..."
FRONTEND_ALB_RESPONSE=$(aws elbv2 create-load-balancer \
    --name portkey-frontend-alb \
    --subnets ${SUBNET_IDS} \
    --security-groups ${PORTKEY_SECURITY_GROUP} \
    --scheme internet-facing \
    --type application \
    --tags Key=Name,Value=portkey-frontend-alb Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION})

FRONTEND_ALB_ARN=$(echo $FRONTEND_ALB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')

# Create Gateway ALB
echo "Creating Gateway ALB..."
GATEWAY_ALB_RESPONSE=$(aws elbv2 create-load-balancer \
    --name portkey-gateway-alb \
    --subnets ${SUBNET_IDS} \
    --security-groups ${PORTKEY_SECURITY_GROUP} \
    --scheme internet-facing \
    --type application \
    --tags Key=Name,Value=portkey-gateway-alb Key=Environment,Value=${ENVIRONMENT} \
    --region ${AWS_REGION})

GATEWAY_ALB_ARN=$(echo $GATEWAY_ALB_RESPONSE | jq -r '.LoadBalancers[0].LoadBalancerArn')

# Create Frontend ALB listener
echo "Creating Frontend ALB listener..."
aws elbv2 create-listener \
    --load-balancer-arn ${FRONTEND_ALB_ARN} \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=${FRONTEND_TG_ARN} \
    --region ${AWS_REGION}

# Create Gateway ALB listener
echo "Creating Gateway ALB listener..."
aws elbv2 create-listener \
    --load-balancer-arn ${GATEWAY_ALB_ARN} \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=${GATEWAY_TG_ARN} \
    --region ${AWS_REGION}

# Output the ALB DNS names
FRONTEND_ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns ${FRONTEND_ALB_ARN} \
    --region ${AWS_REGION} \
    | jq -r '.LoadBalancers[0].DNSName')

GATEWAY_ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns ${GATEWAY_ALB_ARN} \
    --region ${AWS_REGION} \
    | jq -r '.LoadBalancers[0].DNSName')

echo "Frontend ALB DNS Name: ${FRONTEND_ALB_DNS}"
echo "Gateway ALB DNS Name: ${GATEWAY_ALB_DNS}"
