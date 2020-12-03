ARG PYTHON_VERSION=3.8
FROM python:${PYTHON_VERSION}-alpine

ARG VERSION=victoria

ARG USER_ID=1000
ARG GROUP_ID=1000

COPY files/requirements.txt /requirements.txt
COPY run.sh /run.sh
COPY api_monitor.sh /api_monitor.sh

# hadolint ignore=DL3018
RUN apk add --no-cache \
      dumb-init \
      libstdc++ \
    && apk add --no-cache --virtual .build-deps \
      build-base \
      libffi-dev \
      openssl-dev \
      python3-dev \
    && if [ $VERSION = "latest" ]; then wget -P / -O requirements.tar.gz https://tarballs.opendev.org/openstack/requirements/requirements-master.tar.gz; fi \
    && if [ $VERSION != "latest" ]; then wget -P / -O requirements.tar.gz https://tarballs.opendev.org/openstack/requirements/requirements-stable-${VERSION}.tar.gz; fi \
    && mkdir /requirements \
    && tar xzf /requirements.tar.gz -C /requirements --strip-components=1 \
    && rm -rf /requirements.tar.gz \
    && while read -r package; do \
         grep -q "$package" /requirements/upper-constraints.txt && \
         echo "$package" >> /packages.txt || true; \
       done < /requirements.txt \
    && pip3 --no-cache-dir install -c /requirements/upper-constraints.txt -r /packages.txt \
    && rm -rf /requirements \
      /requirements.txt \
      /packages.txt \
    && apk del .build-deps \
    && openstack complete > /osc.bash_completion \
    && addgroup -g $GROUP_ID dragon \
    && adduser -D -u $USER_ID -G dragon dragon \
    && mkdir /configuration \
    && chown -R dragon: /configuration

USER dragon

WORKDIR /configuration
VOLUME ["/configuration"]

CMD ["/run.sh"]
