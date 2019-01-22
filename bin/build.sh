#!/usr/bin/env sh

set -x

if [[ ! -z "${JENKINS_DATA}" ]]; then
    cd $JENKINS_DATA/workspace/$JOB_BASE_NAME
fi

# Build script here
COMPOSE_FILE="magento-$MAGENTO_VERSION/$HTTP_SERVER/docker-compose.php-$PHP_VERSION.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "We do not support for Magento $MAGENTO_VERSION on $HTTP_SERVER with php $PHP_VERSION"
    exit 1
fi

HASH_NAME=`echo -n "$HTTP_SERVER-$PHP_VERSION-$MAGENTO_VERSION-$GITHUB_REPO-$GITHUB_BRANCH" | sha1sum | cut -d' ' -f 1`

if [ -d "$HASH_NAME" ]; then
    echo 'Server is running...'
    sleep $TIME_TO_LIVE
    exit
fi

mkdir $HASH_NAME && cd $HASH_NAME

# Build WebPOS and deploy to Magento Server
GITHUB_URL="https://$GITHUB_USERNAME:$GITHUB_PASSWORD@github.com/$GITHUB_REPO"
IS_PULL=`node -e "if ('$GITHUB_BRANCH'.indexOf('/') !== -1) console.log('1');"`

git init && git remote add origin $GITHUB_URL
if [[ -z "${IS_PULL}" ]]; then
    echo "Checking out branch $GITHUB_BRANCH..."
    git fetch --depth 1 origin $GITHUB_BRANCH
else
    echo "Checking out pull request $GITHUB_BRANCH..."
    git fetch --depth 1 origin +refs/$GITHUB_BRANCH/merge
fi
git checkout FETCH_HEAD

if [ $? -ne 0 ]; then
    exit 1
fi

# Build POS
cd client/pos
npm install && npm run build
cd ../..
mkdir -p server/app/code/Magestore/Webpos/build/apps
rm -Rf server/app/code/Magestore/Webpos/build/apps/pos
cp -Rf client/pos/build server/app/code/Magestore/Webpos/build/apps/pos

# Start service
set +x
cp ../$COMPOSE_FILE docker-compose.yml
docker-compose up -d

PORT=`docker-compose port --protocol=tcp magento 80 | sed 's/0.0.0.0://'`
MAGENTO_URL="http://$NODE_IP:$PORT"

PORT=`docker-compose port --protocol=tcp phpmyadmin 80 | sed 's/0.0.0.0://'`
PHPMYADMIN_URL="http://$NODE_IP:$PORT"

PORT=`docker-compose port --protocol=tcp mailhog 8025 | sed 's/0.0.0.0://'`
EMAIL_URL="http://$NODE_IP:$PORT"

# Check magento installation
COUNT_LIMIT=120 # timeout 600 seconds
while ! RESPONSE=`docker-compose exec -T magento curl -s https://localhost.com/magento_version`
do
    if [ $COUNT_LIMIT -lt 1 ]; then
        break
    fi
    COUNT_LIMIT=$(( COUNT_LIMIT - 1 ))
    sleep 5
done

if [[ ${RESPONSE:0:8} != "Magento/" ]]; then
    docker-compose restart magento
    PORT=`docker-compose port --protocol=tcp magento 80 | sed 's/0.0.0.0://'`
    MAGENTO_URL="http://$NODE_IP:$PORT"
    while ! RESPONSE=`docker-compose exec -T magento curl -s https://localhost.com/magento_version`
    do
        sleep 5
    done
fi

# Correct magento url
docker-compose exec -u www-data -T magento bash -c \
    "php bin/magento setup:store-config:set \
    --admin-use-security-key=0 \
    --base-url-secure=$MAGENTO_URL/ \
    --base-url=$MAGENTO_URL/ "

# Output URLs
echo ""
echo ""
echo "Magento: $MAGENTO_URL/admin"
echo "Admin: admin/admin123"
echo "PHPMyAdmin: $PHPMYADMIN_URL"
echo "EMAIL: $EMAIL_URL"
echo ""

# Living time
set -x
sleep $TIME_TO_LIVE
