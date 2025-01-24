#!/bin/bash

# Check if resources file exists
if [ ! -f "portkey-resources.json" ]; then
    echo "Error: portkey-resources.json not found"
    exit 1
fi

# Read configuration from portkey.env
if [ -f "portkey.env" ]; then
    source portkey.env
else
    echo "Error: portkey.env file not found"
    exit 1
fi

# Configure AWS CLI
aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
aws configure set region ${AWS_REGION}

echo "Starting cleanup of Portkey resources in region ${AWS_REGION}..."

# Delete ECS Services first (to remove dependencies)
CLUSTER_NAME=$(jq -r '.cluster_name' portkey-resources.json)
echo "Scaling down and deleting ECS services..."
for SERVICE in frontend backend gateway redis mysql clickhouse dataservice; do
    echo "Removing service portkey-${SERVICE}..."
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service portkey-${SERVICE} \
        --desired-count 0 \
        --region ${AWS_REGION} 2>/dev/null || true
    
    # Wait for tasks to drain
    echo "Waiting for tasks to drain..."
    sleep 30
    
    aws ecs delete-service \
        --cluster ${CLUSTER_NAME} \
        --service portkey-${SERVICE} \
        --force \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Wait for services to be deleted
echo "Waiting for services to be fully deleted..."
sleep 60

# Delete Load Balancer Listeners first
echo "Deleting Load Balancer Listeners..."
for LB_TYPE in frontend backend gateway redis mysql clickhouse dataservice; do
    LB_ARN=$(jq -r ".load_balancers.${LB_TYPE}" portkey-resources.json)
    LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn ${LB_ARN} --region ${AWS_REGION} 2>/dev/null | jq -r '.Listeners[].ListenerArn')
    for LISTENER in ${LISTENERS}; do
        aws elbv2 delete-listener --listener-arn ${LISTENER} --region ${AWS_REGION} 2>/dev/null || true
    done
done

# Delete Load Balancers
echo "Deleting Load Balancers..."
for LB_TYPE in frontend backend gateway redis mysql clickhouse dataservice; do
    LB_ARN=$(jq -r ".load_balancers.${LB_TYPE}" portkey-resources.json)
    aws elbv2 delete-load-balancer \
        --load-balancer-arn ${LB_ARN} \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Wait for load balancers to be deleted
echo "Waiting for load balancers to be deleted..."
sleep 60

# Delete Target Groups
echo "Deleting Target Groups..."
for TG_TYPE in frontend backend gateway redis mysql clickhouse dataservice; do
    TG_ARN=$(jq -r ".target_groups.${TG_TYPE}" portkey-resources.json)
    aws elbv2 delete-target-group \
        --target-group-arn ${TG_ARN} \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Delete EFS Access Points and File System
echo "Deleting EFS resources..."
EFS_ID=$(jq -r '.efs.filesystem_id' portkey-resources.json)
for AP_TYPE in mysql redis clickhouse; do
    AP_ID=$(jq -r ".efs.access_points.${AP_TYPE}" portkey-resources.json)
    aws efs delete-access-point \
        --access-point-id ${AP_ID} \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Delete mount targets
MOUNT_TARGETS=$(aws efs describe-mount-targets \
    --file-system-id ${EFS_ID} \
    --region ${AWS_REGION} 2>/dev/null | jq -r '.MountTargets[].MountTargetId')
for MT in ${MOUNT_TARGETS}; do
    aws efs delete-mount-target \
        --mount-target-id ${MT} \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Wait for mount targets to be deleted
echo "Waiting for mount targets to be deleted..."
sleep 60

# Delete file system
aws efs delete-file-system \
    --file-system-id ${EFS_ID} \
    --region ${AWS_REGION} 2>/dev/null || true

# Delete Security Groups
echo "Deleting Security Groups..."
PORTKEY_SG=$(jq -r '.security_groups.portkey_sg' portkey-resources.json)
EFS_SG=$(jq -r '.security_groups.efs_sg' portkey-resources.json)

# Remove all inbound rules
for SG in ${PORTKEY_SG} ${EFS_SG}; do
    aws ec2 revoke-security-group-ingress \
        --group-id ${SG} \
        --protocol all \
        --port all \
        --cidr 0.0.0.0/0 \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Remove all outbound rules
for SG in ${PORTKEY_SG} ${EFS_SG}; do
    aws ec2 revoke-security-group-egress \
        --group-id ${SG} \
        --protocol all \
        --port all \
        --cidr 0.0.0.0/0 \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Delete security groups
aws ec2 delete-security-group --group-id ${PORTKEY_SG} --region ${AWS_REGION} 2>/dev/null || true
aws ec2 delete-security-group --group-id ${EFS_SG} --region ${AWS_REGION} 2>/dev/null || true

# Delete CloudWatch Log Groups
echo "Deleting CloudWatch Log Groups..."
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
    aws logs delete-log-group \
        --log-group-name ${LOG_GROUP} \
        --region ${AWS_REGION} 2>/dev/null || true
done

# Delete Docker credentials from Secrets Manager
echo "Deleting Docker credentials from Secrets Manager..."
aws secretsmanager delete-secret \
    --secret-id "portkey/docker-credentials" \
    --force-delete-without-recovery \
    --region ${AWS_REGION} 2>/dev/null || true

# Delete S3 bucket
echo "Deleting S3 bucket..."
BUCKET_NAME="portkey-private-${AWS_ACCOUNT_ID}-${AWS_REGION}"

# Empty the bucket first
aws s3 rm s3://${BUCKET_NAME} --recursive 2>/dev/null || true

# Delete all versions and delete markers
aws s3api delete-objects \
    --bucket ${BUCKET_NAME} \
    --delete "$(aws s3api list-object-versions \
        --bucket ${BUCKET_NAME} \
        --output=json \
        --query='{Objects: [].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true

# Delete the bucket
aws s3api delete-bucket \
    --bucket ${BUCKET_NAME} \
    --region ${AWS_REGION} 2>/dev/null || true

# Delete ECS Cluster
echo "Deleting ECS cluster ${CLUSTER_NAME}..."
aws ecs delete-cluster \
    --cluster ${CLUSTER_NAME} \
    --region ${AWS_REGION} 2>/dev/null || true

# Delete task role policy
echo "Deleting IAM role policy..."
aws iam delete-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-name PortkeySecretsPolicy \
    --region ${AWS_REGION} 2>/dev/null || true

echo "Cleanup complete!"
rm -f portkey-resources.json
