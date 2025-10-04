FROM alpine:latest

RUN apk add --no-cache tinyproxy apache2-utils

COPY config/tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY users/htpasswd /etc/tinyproxy/htpasswd

EXPOSE 8080

CMD ["/usr/sbin/tinyproxy", "-d"]