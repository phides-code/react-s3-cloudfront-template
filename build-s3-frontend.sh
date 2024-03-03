#!/bin/bash

# Check if the user provided one argument
if [ "$#" -ne 1 ]; then
    echo "Usage: build-s3-frontend PROJECT_NAME"
    exit 1
fi

# Assign the argument to a variable
project_name=$1

if [ ! -d "./$project_name" ]; then
  mkdir "./$project_name"
else
    echo "Folder already exists"
    exit 1
fi

### setup vite react-ts-redux app:
npx degit reduxjs/redux-templates/packages/vite-template-redux "$project_name"
cd "$project_name" || exit

### misc updates:
printf "\n.env" >> .gitignore
sed -i "s|React Redux App|$project_name|" index.html
sed -i "s|main|index|" index.html
mv src/main.tsx src/index.tsx
sed -i "s/vite-template-redux/$project_name/g" package.json
rm .prettierrc.json
# this version of counterSlice.test.ts avoids build errors with the version from vite-template-redux
cp "$HOME"/myscripts/build-s3-frontend/counterSlice.test.ts src/features/counter/

### setup aws secrets
# Path to AWS credentials and config files
AWS_CREDENTIALS_FILE="$HOME/.aws/credentials"
AWS_CONFIG_FILE="$HOME/.aws/config"

# Check if the files exist
if [ ! -f "$AWS_CREDENTIALS_FILE" ]; then
  echo "AWS credentials file not found: $AWS_CREDENTIALS_FILE"
  exit 1
fi
if [ ! -f "$AWS_CONFIG_FILE" ]; then
  echo "AWS config file not found: $AWS_CONFIG_FILE"
  exit 1
fi

# Extract aws_access_key_id
AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id" "$AWS_CREDENTIALS_FILE" | head -n 1 | cut -d "=" -f 2 | tr -d '[:space:]')

# Extract aws_secret_access_key
AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key" "$AWS_CREDENTIALS_FILE" | head -n 1 | cut -d "=" -f 2 | tr -d '[:space:]')

# Extract default region
AWS_REGION=$(grep "region" "$AWS_CONFIG_FILE" | head -n 1 | cut -d "=" -f 2 | tr -d '[:space:]')

# Check if the aws variables are empty
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "Failed to extract AWS credentials from file."
  exit 1
fi
if [ -z "$AWS_REGION" ]; then
  echo "Failed to extract AWS region from file."
  exit 1
fi

### Generate UUID 
uuid=$(uuidgen)
short_uuid=${uuid:0:8}

### setup new s3 bucket 
# Combine project name and short UUID
bucket_name="${project_name}-${short_uuid}"

# Create the S3 bucket
aws s3 mb "s3://${bucket_name}"
echo "Created S3 bucket: ${bucket_name}"

### setup cloudfront
# copy cloudfront distribution config, s3 policy, and oac config
cp "$HOME"/myscripts/build-s3-frontend/my-dist-config.json .
cp "$HOME"/myscripts/build-s3-frontend/s3-policy.json .
cp "$HOME"/myscripts/build-s3-frontend/oac-config.json .

# replace placeholder names in json files 
sed -i "s|BUCKET_NAME|$bucket_name|" my-dist-config.json
sed -i "s|CALLER_REFERENCE|$uuid|" my-dist-config.json
sed -i "s|AWS_REGION|$AWS_REGION|" my-dist-config.json
sed -i "s|BUCKET_NAME|$bucket_name|" s3-policy.json
sed -i "s|BUCKET_NAME|$bucket_name|" oac-config.json

# create oac, capture the oac id and insert in my-dist-config.json
oac_create_response=$(aws cloudfront create-origin-access-control --origin-access-control-config file://oac-config.json)
oac_id=$(echo "$oac_create_response" | jq -r '.OriginAccessControl.Id')
sed -i "s|OAC_ID|$oac_id|" my-dist-config.json

# create cloudfront distribution and capture the ARN 
dist_create_response=$(aws cloudfront create-distribution --distribution-config file://my-dist-config.json)
arn=$(echo "$dist_create_response" | jq -r '.Distribution.ARN')
dist_domain=$(echo "$dist_create_response" | jq -r '.Distribution.DomainName')
distribution_id=$(echo "$dist_create_response" | jq -r '.Distribution.Id')
echo "Created distribution ${distribution_id}"

# update s3-policy.json with ARN
sed -i "s|SOURCE_ARN|$arn|" s3-policy.json

# update s3 bucket policy
aws s3api put-bucket-policy --bucket "$bucket_name" --policy file://s3-policy.json

# remove json files
rm my-dist-config.json
rm s3-policy.json
rm oac-config.json

### setup github workflow:
mkdir .github
mkdir .github/workflows
cp "$HOME"/myscripts/build-s3-frontend/main.yml .github/workflows/main.yml

### setup git repo:
git init
gh repo create

### Set GitHub secrets using 
gh secret set AWS_DISTRIBUTION --body "$distribution_id"
gh secret set AWS_S3_BUCKET --body "$bucket_name"
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"
gh secret set AWS_REGION --body "$AWS_REGION"
echo "AWS secrets set in GitHub Actions."

### initial commit:
git add .
git commit -m "initial commit"
git push origin main

echo ""
echo "Created distribution at domain: https://${dist_domain}"

