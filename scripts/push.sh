#!/usr/bin/env bash
set -x

# Available environment variables
#
# DOCKER_REGISTRY
# REPOSITORY
# VERSION

# Set default values

DOCKER_REGISTRY=${DOCKER_REGISTRY:-quay.io}
VERSION=${VERSION:-latest}

if [[ -n $DOCKER_REGISTRY ]]; then
    REPOSITORY="$DOCKER_REGISTRY/$REPOSITORY"
fi

if [[ $VERSION == "latest" ]]; then
    docker push "$REPOSITORY:$VERSION"
else
    if skopeo inspect --creds "${DOCKER_USERNAME}:${DOCKER_PASSWORD}" "docker://${REPOSITORY}:${VERSION}" > /dev/null; then
        echo "The image ${REPOSITORY}:${VERSION} already exists."
    else
        docker push "$REPOSITORY:$VERSION"
    fi
fi

docker rmi "$REPOSITORY:$VERSION"
