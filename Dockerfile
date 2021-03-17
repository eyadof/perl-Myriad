FROM deriv/dzil
ARG HTTP_PROXY

WORKDIR /app
ONBUILD COPY . /app/
ONBUILD RUN prepare-apt-cpan.sh \
 && dzil authordeps | cpanm -n

RUN dzil install \
 && dzil clean \
 && git clean -fd \
 && apt purge --autoremove -y \
 && rm -rf .git .circleci

ENV MYRIAD_DEV=${MYRID_DEV}

ENTRYPOINT [ "bin/start.sh" ]

