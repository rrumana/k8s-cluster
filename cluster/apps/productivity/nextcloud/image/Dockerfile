ARG NEXTCLOUD_IMAGE=harbor.rcrumana.xyz/mirror/library/nextcloud:33.0.0-apache@sha256:ce6282022fc52a28315b9d4bf18820d847aa2a4b8394dfe4039c8a4220b4b08c

FROM alpine:3.23 AS user-oidc
ARG USER_OIDC_VERSION=8.10.1
ARG USER_OIDC_SHA256=49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd
RUN apk add --no-cache ca-certificates curl \
    && curl --fail --location --show-error \
      "https://github.com/nextcloud-releases/user_oidc/releases/download/v${USER_OIDC_VERSION}/user_oidc-v${USER_OIDC_VERSION}.tar.gz" \
      --output /tmp/user_oidc.tar.gz \
    && echo "${USER_OIDC_SHA256}  /tmp/user_oidc.tar.gz" | sha256sum -c \
    && mkdir -p /out \
    && tar --extract --gzip --file /tmp/user_oidc.tar.gz --directory /out

FROM ${NEXTCLOUD_IMAGE}
COPY --from=user-oidc --chown=www-data:www-data \
  /out/user_oidc /usr/src/nextcloud/custom_apps/user_oidc
