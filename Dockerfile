ARG PYTHON_VERSION=3.8
FROM python:${PYTHON_VERSION}-alpine

ARG VERSION=xena

ARG USER_ID=45000
ARG GROUP_ID=45000

COPY files/requirements.txt /requirements.txt
COPY api_monitor.sh /api_monitor.sh

ENV CRYPTOGRAPHY_DONT_BUILD_RUST 1
# hadolint ignore=DL3018
RUN apk add --no-cache \
      bash \
      iputils \
      jq \
      libstdc++ \
      openssh-client \
      curl \
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
    && mkdir /configuration /data \
    && chown -R dragon: /configuration /data \
    && chmod +x /api_monitor.sh

USER dragon

WORKDIR /configuration
VOLUME ["/configuration", "/data"]

CMD ["/api_monitor.sh -O -C -D -N 2 -n 8 -s -L -b -B -a 2 -t -T -R -s -i 5"]
ENTRYPOINT ["/api_monitor.sh"]
